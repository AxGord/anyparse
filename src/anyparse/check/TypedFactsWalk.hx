package anyparse.check;

#if macro
import anyparse.check.TypedFactsMacro.InlineMethod;
import anyparse.check.TypedFactsShapes.FieldRef;
import haxe.Json;
import haxe.macro.Context;
import haxe.macro.Expr.Position;
import haxe.macro.Type;
import haxe.macro.TypeTools;
import haxe.macro.TypedExprTools;

using StringTools;

/**
 * One node's facts: the walk over one function or initializer body. A nested function is a node of its own, spawned
 * by the walk and named in the parent's `fns`. Each category is deduplicated, since the compiler unrolls a loop over a
 * constant array into copies that carry the same positions.
 */
@:nullSafety(Strict)
final class TypedFactsWalk {

	/** The categories of a node line, in the order they are written. */
	private static final CATEGORIES: Array<String> = [
		'params', 'calls', 'news', 'fields', 'elems', 'flows', 'hands', 'gens', 'strs', 'iters', 'refl', 'native', 'vars', 'reads', 'exps',
		'fns'
	];

	/** The accesses of a call of a method a type declares, whose parameters take its arguments (`Argument`). */
	private static final DECLARED_CALLS: Array<String> = ['FStatic', 'FInstance'];

	/**
	 * An abstract, by path, -> the type it wraps and its type parameters, or null for a `@:coreType` one (`wrapped`). An
	 * abstract's declaration is the same for the whole compile, every round of the hook included.
	 */
	private static final abstractBodies: Map<String, Null<{ type: Type, params: Array<TypeParameter> }>> = [];

	public final id: String;

	private final _facts: Map<String, Array<String>> = [];
	private final _seen: Map<String, Bool> = [];

	/** The type string of each local by id, rendered once: a local is read far more often than declared. */
	private final _localTypes: Map<Int, String> = [];

	/** What this node's facts cannot capture exactly, for the consumer to answer Unknown. */
	private final _incomplete: Array<String> = [];

	private final _host: TypedFactsMacro;
	private final _kind: String;
	private final _owner: String;
	private final _isStatic: Bool;
	private final _signature: String;
	private final _name: Null<String>;
	private final _locals: Map<Int, String>;
	private final _written: Map<Int, Bool>;

	/**
	 * Every local a `var` of the walked code declares, by id, with the uses its reads make, shared with the nested walks:
	 * a field read stored in one (`Held`) is used as each of them, so the read is recorded once the uses are known. A read
	 * from a nested function captures the value.
	 */
	private final _aliases: Map<Int, Alias>;

	/**
	 * The locals initialized with a construction of exactly their own type, by id: one never written again (`_written`)
	 * holds that one object of that class for as long as it lives. Shared with the nested walks.
	 */
	private final _built: Map<Int, Bool>;

	/**
	 * The locals initialized with an object literal, by id: one never written again (`_written`) holds that one structure,
	 * no instance of a class, for as long as it lives. Shared with the nested walks.
	 */
	private final _literals: Map<Int, Bool>;

	/** The field reads held back until their local's uses are known: the fact without its use, and the local. */
	private final _deferred: Array<{ fact: String, local: Int }> = [];

	/** How the value of the expression `walk` is about to visit is used; `visit` takes it and resets it to `Value`. */
	private var _use: FactUse = Value;

	/**
	 * The method whose spliced body the expression `walk` is about to visit was substituted into from its call site — code
	 * of the body's own text directly under that method's code — or null; `visit` takes it and resets it.
	 */
	private var _substituted: Null<InlineMethod> = null;

	/** The range of the block the expression `walk` is about to visit is a statement of; `visit` takes it and resets it. */
	private var _block: Null<Position> = null;

	private var _ret: Null<Type> = null;
	private var _home: String = '';

	/** The body's range in `_home`: an expression outside it was spliced in by inlining or a macro. */
	private var _min: Int = 0;

	private var _max: Int = 0;

	/** Whether the innermost walked expression lies in the body's own range. */
	private var _inBody: Bool = true;

	/**
	 * The range of the innermost walked expression that lies in the body's own range: it holds the call site a body
	 * spliced below it replaced — the whole body while none does, and under a range that meets the body without lying in it.
	 */
	private var _site: { min: Int, max: Int } = { min: 0, max: 0 };

	/** The method whose spliced body is being walked; null in the body's own code, and in a splice no method was found for. */
	private var _splice: Null<InlineMethod> = null;

	/**
	 * The range of the innermost walked expression that lies in `_splice`'s declared range: the code of that method that
	 * holds what is walked below it — the whole declared range while none does.
	 */
	private var _spliceSite: { min: Int, max: Int } = { min: 0, max: 0 };

	/** The macro method whose expansion, spliced into `_splice`'s code, is being walked (`nestedSplice`); null otherwise. */
	private var _expansion: Null<InlineMethod> = null;

	/** Extra header fields: `gen`, `gi`, `inl`, `ov`. */
	private var _header: String = '';

	/**
	 * The field chain rooted at a native identifier being walked (`nativeChain`): the identifier, the target code the chain
	 * spells, and the arguments a call through it hands that code; null otherwise.
	 */
	private var _nativeChain: Null<NativeChain> = null;

	public function new(
		host: TypedFactsMacro, id: String, kind: String, owner: String, isStatic: Bool, signature: String, name: Null<String>,
		locals: Map<Int, String>, written: Map<Int, Bool>, aliases: Map<Int, Alias>, built: Map<Int, Bool>, literals: Map<Int, Bool>
	) {
		this._host = host;
		this.id = host.uniqueId(id);
		this._kind = kind;
		this._owner = owner;
		this._isStatic = isStatic;
		this._signature = signature;
		this._name = name;
		this._locals = locals;
		this._written = written;
		this._aliases = aliases;
		this._built = built;
		this._literals = literals;
	}

	/** Mark the node with a header flag (`gen`: macro-placed; `gi`: a `@:generic` instance's copy), kept out of file ranges. */
	public function flag(name: String): TypedFactsWalk {
		_header += ',"$name":true';
		return this;
	}

	/** Mark the node as the `index`-th overload of its field. */
	public function markOverload(index: Int): TypedFactsWalk {
		_header += ',"ov":$index';
		return this;
	}

	/** Walk `e`, the node's whole body — a function for a method, the value for a variable — and write the node's line. */
	public function root(e: TypedExpr): Void {
		final info: { min: Int, max: Int, file: String } = Context.getPosInfos(e.pos);
		_home = info.file;
		_min = info.min;
		_max = info.max;
		_site = { min: _min, max: _max };
		_host.noteHome(_home);
		final at: String = '[$_min,$_max]';
		switch e.expr {
			case TFunction(f):
				_ret = f.t;
				final kept: Array<Int> = [];
				for (i => a in f.args) {
					add('params', '{"n":${q(a.v.name)},"t":${q(localType(a.v))}}');
					// no code of the body assigns it and no default replaces a null handed to it: it holds what the call hands
					if (a.value == null && !_written.exists(a.v.id)) kept.push(i);
					// a parameter is a local of this node: its reads are the uses of what a call hands it
					final param: Alias = { owner: id, uses: [], links: [] };
					_aliases[a.v.id] = param;
				}
				if (kept.length > 0) _header += ',"pk":[${kept.join(',')}]';
				// a function's body is never its value: a returned value is the operand of a `return`
				walkAs(f.expr, Statement);
				final handed: Array<String> = [for (a in f.args) '[' + [for (u in aliasUses(a.v.id)) '{$u}'].join(',') + ']'];
				_header += ',"pu":[${handed.join(',')}]';
			case _:
				walk(e);
		}
		for (d in _deferred) {
			final seen: Array<String> = aliasUses(d.local);
			// a local never read is answered as any use the walk does not name
			final uses: Array<String> = seen.length > 0 ? seen : [useText(Value)];
			for (u in uses) add('fields', d.fact + ',"h":true,' + u + '}');
		}
		final out: StringBuf = new StringBuf();
		out.add('{"k":"node","id":${q(id)},"f":${q(_home)},"p":$at,"kind":"$_kind","owner":${q(_owner)},"t":${q(_signature)}');
		if (_isStatic) out.add(',"s":true');
		final localName: Null<String> = _name;
		if (localName != null) out.add(',"name":${q(localName)}');
		out.add(_header);
		if (_incomplete.length > 0) out.add(',"inc":' + TypedFactsMacro.arr([for (i in _incomplete) q(i)]));
		for (category in CATEGORIES) {
			final list: Null<Array<String>> = _facts[category];
			if (list != null) out.add(',"$category":' + TypedFactsMacro.arr(list));
		}
		out.add('}');
		_host.nodes++;
		_host.line(out.toString());
	}

	/**
	 * `p` as a fact position: `[min,max]` in the node's file, else `[i,min,max]`. A position in a `Reflect`/`Type` module
	 * marks the node `reflection-inlined`, and names the method whose declared code holds it (`reflection-from:<id>`), or
	 * says none does (`reflection-unattributed`).
	 */
	private function at(p: Position): String {
		final info: { min: Int, max: Int, file: String } = Context.getPosInfos(p);
		if (info.file == _home) return '[${info.min},${info.max}]';
		if (_host.reflectionModule(info.file)) {
			incomplete('reflection-inlined');
			// the method whose declared code holds the fact: the reflective body it stands in, or none that says
			final from: Null<InlineMethod> = _host.inlineCallee(info.file, info.min, info.max);
			incomplete(from == null ? 'reflection-unattributed' : 'reflection-from:' + from.id);
		}
		return _host.pos(p, _home);
	}

	private function incomplete(channel: String): Void {
		if (!_incomplete.contains(channel)) _incomplete.push(channel);
	}

	private function add(category: String, fact: String): Void {
		final key: String = category + fact;
		if (_seen.exists(key)) return;
		_seen[key] = true;
		final list: Null<Array<String>> = _facts[category];
		if (list == null)
			_facts[category] = [fact]
		else
			list.push(fact);
	}

	private function localType(v: TVar): String {
		final known: Null<String> = _localTypes[v.id];
		if (known != null) return known;
		final rendered: String = str(v.t);
		_localTypes[v.id] = rendered;
		return rendered;
	}

	private function declare(v: TVar, p: Position): Void {
		if (!v.name.startsWith('`')) add('vars', '{"n":${q(v.name)},"t":${q(str(v.t))},"p":${at(p)}}');
	}

	/**
	 * `value` reaching a place of type `to`: once per value-producing leaf — both branches of an `if`, every case of a
	 * `switch`, a `try` and its catches, a block's last expression — each at its own type, since the unified type of the
	 * whole says nothing about what each branch carries. An unbound monomorph as the place is a place of no type.
	 */
	private function flowInto(value: TypedExpr, to: String, how: String, p: Position): Void {
		final sink: String = to == '?' ? 'Dynamic' : to;
		final leaves: Array<TypedExpr> = [];
		TypedFactsShapes.collectLeaves(value, leaves);
		if (leaves.length == 1 && leaves[0] == value)
			flowText(sourceType(value), sink, how, p, exactObject(value));
		else
			for (leaf in leaves) flowText(sourceType(leaf), sink, how, leaf.pos, exactObject(leaf));
	}

	/**
	 * The type of the value `leaf` carries: its own, unless `untyped` retyped it — a local or a field still holds a value
	 * of the type it was declared with, whatever the untyped expression reads as. A declared type naming a type parameter
	 * is left to the expression's own, which has it substituted.
	 */
	private function sourceType(leaf: TypedExpr): String {
		final own: String = str(leaf.t);
		final declared: Null<Type> = switch leaf.expr {
			case TLocal(v): v.t;
			case TField(_, FInstance(_, _, cf) | FStatic(_, cf)): cf.get().type;
			case _: null;
		};
		if (declared == null) return own;
		final written: String = str(declared);
		return written == '?' || written.indexOf('$') >= 0 ? own : written;
	}

	/**
	 * A value of type `s` reaching a place of type `d`, kept only when the two differ beyond nullability; `x` when it is an
	 * object of exactly its own class (`exactObject`).
	 */
	private function flowText(s: String, d: String, how: String, p: Position, exact: Bool = false): Void {
		if (how != 'cast' && FactsTypeText.unwrapNull(s) == FactsTypeText.unwrapNull(d)) return;
		add('flows', '{"s":${q(s)},"d":${q(d)},"c":"$how","p":${at(p)}' + (exact ? ',"x":true}' : '}'));
	}

	private function child(f: TypedExpr, localName: Null<String>): String {
		final info: { min: Int, max: Int, file: String } = Context.getPosInfos(f.pos);
		final nested: TypedFactsWalk = new TypedFactsWalk(
			_host, '$id@${info.min}', localName == null ? 'fn' : 'local', _owner, _isStatic, str(f.t), localName, _locals, _written,
			_aliases, _built, _literals
		);
		// a function outside this body was spliced in: it runs here, but no range of its own file is where it runs. One
		// bound straight to a local is reached without `walk`, so the splice is decided here too
		final inside: Bool = info.file == _home && info.min >= _min && info.max <= _max;
		final splice: Null<InlineMethod> = _splice;
		if (_inBody && !inside) spliced(f, info);
		_splice = splice;
		if (!_inBody || !inside) nested._header += ',"inl":${q(id)}';
		add('fns', q(nested.id));
		nested.root(f);
		return nested.id;
	}

	/**
	 * Walk `e`. The first expression outside the body's own range — another file, or elsewhere in this one — is the root of
	 * a spliced body: an inlined function, or a macro's expansion. The compiler keeps no range for the call site it
	 * replaced, so the node says where it cannot: `inline-site-unknown`, and `macro-expansion` when no method holds the
	 * spliced code. A constant or a type expression is left out: the compiler places a default argument's value, or an
	 * inlined constant, at its declaration — save a constant inside a spliced body lying in the declared range of another
	 * inline method (`splicedCode`): that method's code wrote it as an argument of the inline call it made, so its body
	 * was spliced as well, although the constants are all of it the compiler kept (`return limit(v, 0, 1)`). So is a range that meets the body without lying inside it: the compiler's
	 * union of the body's own code with a range around it — an abstract method's `this` stands at the whole abstract, an
	 * operand shares a range with an inlined sibling — whose parts are asked one by one. Inside a spliced body, code of
	 * another method is a body that one spliced in turn (`nestedSplice`).
	 */
	private function walk(e: TypedExpr): Void {
		final info: { min: Int, max: Int, file: String } = Context.getPosInfos(e.pos);
		final inside: Bool = info.file == _home && info.min >= _min && info.max <= _max;
		final straddles: Bool = !inside && info.file == _home && info.min <= _max && info.max >= _min;
		final saved: Bool = _inBody;
		final site: { min: Int, max: Int } = _site;
		final splice: Null<InlineMethod> = _splice;
		final spliceSite: { min: Int, max: Int } = _spliceSite;
		final expansion: Null<InlineMethod> = _expansion;
		final code: Bool = !e.expr.match(TConst(_) | TTypeExpr(_));
		if (inside)
			_site = { min: info.min, max: info.max }
		else if (straddles)
			_site = { min: _min, max: _max };
		if (inside || straddles) {
			_splice = null;
			_expansion = null;
		} else if (saved && code)
			spliced(e, info)
		else if (splice != null && splicedCode(e, info, code) && !holds(splice, info) && (expansion == null || !holds(expansion, info)))
			nestedSplice(e, info);
		final current: Null<InlineMethod> = _splice;
		if (current != null && holds(current, info)) _spliceSite = { min: info.min, max: info.max };
		// back inside, as the call site's own arguments are: a further splice there is a call of its own
		_inBody = inside || straddles;
		_substituted = inside && !saved ? splice : null;
		visit(e);
		_inBody = saved;
		_site = site;
		_splice = splice;
		_spliceSite = spliceSite;
		_expansion = expansion;
	}

	/**
	 * The inline method whose code writes the field access `e`, whose range `info` the compiler joined from its receiver's
	 * code and the field it names (a getter's `base.folder`: what the inline `base` returned, then the getter's `.folder`),
	 * keeping the receiver's file: the end the receiver does not supply is where that method's code spells `.` and the
	 * field — a check the end must pass, since a field written in another file than the receiver's leaves an offset of
	 * that file there. Null for any other expression.
	 */
	private function fieldWriter(e: TypedExpr, info: { min: Int, max: Int, file: String }): Null<InlineMethod> {
		final field: Null<{ receiver: TypedExpr, name: String }> = switch e.expr {
			case TField(receiver, access): { receiver: receiver, name: TypedFactsShapes.describe(access).field };
			case _: null;
		};
		if (field == null) return null;
		final receiver: { min: Int, max: Int, file: String } = Context.getPosInfos(field.receiver.pos);
		if (receiver.file != info.file) return null;
		final name: String = field.name;
		if (info.max > receiver.max && _host.spellsAccess(info.file, info.max - name.length, name))
			return _host.inlineCallee(info.file, info.max, info.max);
		if (info.min < receiver.min && _host.spellsAccess(info.file, info.min, name))
			return _host.inlineCallee(info.file, info.min, info.min);
		return null;
	}

	/**
	 * Whether `e`, at `info` in a spliced body, is code of a method spliced there: code (`code`), or a constant lying in
	 * an inline method's declared range, which that method's code wrote as an argument of the inline call it made.
	 */
	private function splicedCode(e: TypedExpr, info: { min: Int, max: Int, file: String }, code: Bool): Bool {
		return code || (e.expr.match(TConst(_)) && _host.inlineCallee(info.file, info.min, info.max) != null);
	}

	/** Whether the range `info` of an expression lies in the body's own range: code of the body's text. */
	private inline function own(info: { min: Int, max: Int, file: String }): Bool {
		return info.file == _home && info.min >= _min && info.max <= _max;
	}

	/**
	 * The range of the body's own code between the statements of `exprs` around the `index`-th — the end of the last one
	 * before it that is own code (`own`) to the start of the first one after it — within `outer`, the range of the
	 * innermost own code holding them all; `outer` itself unless that range holds every own code of the statement
	 * (`holdsOwnCode`): the compiler places code of its own at the whole block — the `this` a closure among an inlined
	 * call's arguments captures, bound ahead of the splice — and a range bounded by it is no text the call is written in.
	 */
	private function between(
		exprs: Array<TypedExpr>, ranges: Array<{ min: Int, max: Int, file: String }>, index: Int, outer: { min: Int, max: Int }
	): { min: Int, max: Int } {
		var min: Int = outer.min;
		var max: Int = outer.max;
		for (j in 0...index) if (own(ranges[j])) {
			final end: Int = ranges[j].max;
			if (end > min) min = end;
		}
		for (j in index + 1...exprs.length) if (own(ranges[j])) {
			max = ranges[j].min;
			break;
		}
		final site: { min: Int, max: Int } = { min: min, max: max };
		return min <= max && outer.min <= min && max <= outer.max && holdsOwnCode(exprs[index], site) ? site : outer;
	}

	/** Whether `site` holds the range of every expression of `e` that is own code (`own`), `e` among them. */
	private function holdsOwnCode(e: TypedExpr, site: { min: Int, max: Int }): Bool {
		final info: { min: Int, max: Int, file: String } = Context.getPosInfos(e.pos);
		if (own(info) && (info.min < site.min || info.max > site.max)) return false;
		var held: Bool = true;
		TypedExprTools.iter(e, x -> if (held && !holdsOwnCode(x, site)) held = false);
		return held;
	}

	/** Whether `info` lies in the declared range of `method`. */
	private static inline function holds(method: InlineMethod, info: { min: Int, max: Int, file: String }): Bool {
		return info.file == method.file && info.min >= method.min && info.max <= method.max;
	}

	/** Walk `e`, whose value is used as `use`. */
	private function walkAs(e: TypedExpr, use: FactUse): Void {
		_use = use;
		walk(e);
	}

	/**
	 * Record the spliced body rooted at `e`: the call of the method it came from — `inline`, or inlined by its call site — found at the root or, when
	 * the root carries a position of its own — an abstract's `this` stands at the whole abstract — at the first
	 * expression under it that lies in one; `macro-expansion` when none does, and then, where a macro method's declared
	 * range holds the root, the expansion of that macro (`expanded`) at the innermost expression of the body around it.
	 * The call carries where it ran, the range of the innermost expression of the body around it (`_site`), and the
	 * method's declared range, which holds its code.
	 */
	private function spliced(e: TypedExpr, info: { min: Int, max: Int, file: String }): Void {
		incomplete('inline-site-unknown');
		var callee: Null<InlineMethod> = _host.inlineCallee(info.file, info.min, info.max);
		if (callee == null) {
			final pending: Array<TypedExpr> = [];
			TypedExprTools.iter(e, x -> pending.push(x));
			while (callee == null && pending.length > 0) {
				final next: TypedExpr = pending.shift() ?? e;
				final at: { min: Int, max: Int, file: String } = Context.getPosInfos(next.pos);
				// the call site's own arguments sit in this body, which holds no method that could have been spliced here
				if (at.file == _home && at.min >= _min && at.max <= _max) continue;
				callee = _host.inlineCallee(at.file, at.min, at.max);
				if (callee == null) TypedExprTools.iter(next, x -> pending.push(x));
			}
		}
		if (callee == null) {
			incomplete('macro-expansion');
			expanded(_host.macroCallee(info.file, info.min, info.max), e.pos, _home, _site);
			return;
		}
		inlinedCall(callee, e.t, at(e.pos));
	}

	/**
	 * A spliced body walked below the one of `_splice` that is none of its method's code: a body that method's code spliced
	 * in turn, run at the same site — the method declared around it, or the one writing a field access whose range the
	 * compiler joined across two methods' code (`fieldWriter`) — or the expansion of a macro that code calls (`expanded`), at the innermost
	 * expression of that code around it (`_spliceSite`). Code no method holds stays the outer body's.
	 */
	private function nestedSplice(e: TypedExpr, info: { min: Int, max: Int, file: String }): Void {
		final callee: Null<InlineMethod> = _host.inlineCallee(info.file, info.min, info.max);
		if (callee != null) {
			inlinedCall(callee, e.t, at(e.pos));
			return;
		}
		final written: Null<InlineMethod> = fieldWriter(e, info);
		if (written != null && written != _splice) {
			inlinedCall(written, e.t, at(e.pos));
			return;
		}
		final splice: Null<InlineMethod> = _splice;
		final expander: Null<InlineMethod> = _host.macroCallee(info.file, info.min, info.max);
		if (splice == null || expander == null) return;
		expanded(expander, e.pos, splice.file, _spliceSite);
		_expansion = expander;
	}

	/**
	 * The expansion of the macro `expander`, rooted at `root`, written into the code of `file` at `anchor`: the innermost
	 * expression of that code around the expansion, which holds the call of the macro the compiler replaced (`a`), and
	 * the macro's declared range (`d`), which holds the code it built. With no macro declared around the root the record
	 * names none: code no method is known to hold.
	 */
	private function expanded(expander: Null<InlineMethod>, root: Position, file: String, anchor: { min: Int, max: Int }): Void {
		final written: String = _host.range(file, anchor.min, anchor.max, _home);
		final built: String = expander == null
			? ''
			: ',"t":${q(expander.id)},"d":${_host.range(expander.file, expander.min, expander.max, _home)}';
		add('exps', '{"p":${at(root)},"a":$written$built}');
	}

	/**
	 * The call of `callee`, whose body was spliced in at `where` with the result type `result`: the current site (`s`) and
	 * the method's declared range (`d`). What is walked below it is that method's.
	 */
	private function inlinedCall(callee: InlineMethod, result: Type, where: String): Void {
		final declared: String = _host.range(callee.file, callee.min, callee.max, _home);
		add('calls', '{"t":${q(callee.id)},"a":"inlined","rt":${q(str(result))},"p":$where,"s":[${_site.min},${_site.max}],"d":$declared}');
		_splice = callee;
		_spliceSite = { min: callee.min, max: callee.max };
		_expansion = null;
	}

	private function visit(e: TypedExpr): Void {
		// noqa: complexity
		final use: FactUse = _use;
		_use = Value;
		final block: Null<Position> = _block;
		_block = null;
		final substituted: Null<InlineMethod> = _substituted;
		_substituted = null;
		switch e.expr {
			case TFunction(_):
				child(e, null);
			case TLocal(v):
				if (!v.name.startsWith('`')) add('reads', '[${range(e.pos)},${q(localType(v))}]');
				final alias: Null<Alias> = _aliases[v.id];
				if (alias != null) localRead(alias, v, use, substituted);
			case TIdent(identifier):
				// the root of a field chain spells the chain as its code, and is handed what a call through it is
				final chain: Null<NativeChain> = _nativeChain;
				final rooted: String = chain != null && chain.root == e ? ',"c":${q(chain.text)}' + handedText(chain.handed) : '';
				add('native', '{"w":"ident","n":${q(identifier)},"p":${at(e.pos)}$rooted}');
			case TTypeExpr(m):
				// a reflection class read as a value takes every one of its members along
				final name: String = TypedFactsShapes.moduleTypeId(m);
				if (TypedFactsShapes.REFLECTION_CLASSES.contains(name)) add('refl', '{"t":${q(name)},"v":true,"p":${at(e.pos)}}');
			case TVar(v, init):
				declare(v, e.pos);
				// an unrolled loop declares one local once per copy, and every copy's reads are its uses
				final alias: Alias = _aliases[v.id] ?? { owner: id, uses: [], links: [] };
				_aliases[v.id] = alias;
				if (init != null) {
					flowInto(init, str(v.t), 'var', e.pos);
					if (constructed(init) && str(init.t) == localType(v)) _built[v.id] = true;
					if (objectLiteral(init)) _literals[v.id] = true;
					final called: Null<String> = receiverCall(v, e.pos, block);
					switch init.expr {
						case TFunction(_):
							final made: String = child(init, v.name);
							if (!_written.exists(v.id)) _locals[v.id] = made;
						case _ if (called != null):
							// the receiver of an inlined call: what the method's code then does with it is the call's
							walkAs(init, Call(called));
						case _ if (heldValue(init)):
							// the value goes wherever the local's reads take it: the compiler holds a lowered loop's array, and the
							// receiver of a compound element write, in a local of its own; a branch of an if-expression hands its
							// value on just as directly
							walkAs(init, Held(v.id));
						case _:
							walk(init);
					}
				}
			case TCall(callee, args):
				call(e, callee, args);
			case TNew(c, params, args):
				// the `@:genericBuild` class the text constructs, of which the compiler built `c`
				final generic: Null<String> = _host.genericBuilt(c, e.pos);
				add(
					'news',
					'{"t":${q(c.toString())},"ty":${q(str(e.t))},"p":${at(e.pos)}' + (generic == null ? '' : ',"gb":${q(generic)}') + '}'
				);
				final cls: ClassType = c.get();
				final ctor: Null<Ref<ClassField>> = cls.constructor;
				if (ctor != null) argFlows(TypeTools.applyTypeParameters(ctor.get().type, cls.params, params), args);
				if (ctor != null) handed(cls, ctor.get(), '${c.toString()}.new', args);
				for (a in args) walk(a);
			case TField(receiver, fa):
				switch use {
					case Held(local):
						_deferred.push({ fact: fieldHead(e, receiver, fa, false), local: local });
					case _:
						fieldFact(e, receiver, fa, false, ',' + useText(use));
				}
				reflectionValue(fa, e);
				instantiated(fa, e.t, e.pos);
				final chained: Bool = nativeChain(e, []);
				// a method closure holds its receiver; any other field access reads through it
				walkReceiver(receiver, fa.match(FClosure(_, _)) ? Value : Member);
				if (chained) _nativeChain = null;
			case TArray(array, index):
				walkAs(array, Index);
				walk(index);
			case TBinop(OpAssign, lhs, rhs):
				flowInto(rhs, str(lhs.t), 'assign', e.pos);
				// a fresh value stored by an assignment whose own value goes nowhere is held by its target alone
				target(lhs, false, use == Statement && TypedFactsShapes.isFresh(rhs));
				// a field's or a local's value stored by such an assignment in a local of this node goes where the local's reads take it
				final into: Null<Int> = use == Statement ? storedLocal(lhs, rhs) : null;
				if (into == null)
					walk(rhs)
				else
					walkAs(rhs, Held(into));
			case TBinop(OpAssignOp(op), lhs, rhs):
				if (op == OpAdd && TypedFactsShapes.isString(lhs.t) && !TypedFactsShapes.isString(rhs.t)) stringSite(rhs);
				target(lhs, true, false);
				walk(rhs);
			case TUnop(OpIncrement | OpDecrement, _, operand):
				target(operand, true, false);
			case TBinop(OpAdd, a, b) if (TypedFactsShapes.isString(e.t)):
				for (operand in [a, b]) if (!TypedFactsShapes.isString(operand.t)) stringSite(operand);
				walk(a);
				walk(b);
			case TBinop(OpEq | OpNotEq | OpLt | OpLte | OpGt | OpGte, a, b):
				walkAs(a, Compare);
				walkAs(b, Compare);
			case TReturn(value):
				if (value != null) {
					flowInto(value, str(_ret), 'ret', e.pos);
					walk(value);
				}
			case TThrow(value):
				flowInto(value, 'Dynamic', 'throw', e.pos);
				// the exception wrapping the compiler adds after typing hands a thrown value to `Std.string` (`haxe.ValueException`)
				if (!TypedFactsShapes.isString(value.t) && !thrownAsIs(value)) stringSite(value);
				walk(value);
			case TArrayDecl(items):
				for (item in items) walk(item);
				literalFlows(e);
			case TObjectDecl(entries):
				for (entry in entries) walk(entry.expr);
				literalFlows(e);
			case TCast(inner, null):
				// an unchecked cast is recorded whatever the two types: its source is what escapes
				final sink: String = str(e.t);
				flowText(sourceType(inner), sink == '?' ? 'Dynamic' : sink, 'cast', e.pos);
				// one to the type the value already has changes nothing, so the value is used as the cast is: an inlined
				// abstract method reads its `this` through one (`Map.get` calls `(cast this).get(key)`), and a local spliced in as
				// that `this` is cast from the abstract to the type it wraps, which is what it is at run time. An argument stays
				// the object it was whatever it is cast to — the compiler casts a `Map` handed to an `Iterable` — and the
				// parameter's uses name what is done to that object
				final same: Bool = sink == str(inner.t) || sink == str(wrapped(inner.t));
				if ((sink != '?' && same) || use.match(Argument(_, _, _)))
					walkAs(inner, use)
				else
					walk(inner);
			case TFor(v, it, body):
				declare(v, e.pos);
				add('iters', '{"v":${q(str(v.t))},"i":${q(str(it.t))},"p":${at(e.pos)}}');
				walkAs(it, Iterable);
				walkAs(body, Statement);
			case TWhile(condition, body, _):
				walk(condition);
				walkAs(body, Statement);
			case TBlock(exprs):
				// every statement but the last is discarded; the last is the block's own value. Each statement's range is
				// read once for the block: `between` asks every other one's, per statement not of the body's own code
				final ranges: Array<{ min: Int, max: Int, file: String }> = [for (x in exprs) Context.getPosInfos(x.pos)];
				for (i in 0...exprs.length) {
					_block = e.pos;
					final site: { min: Int, max: Int } = _site;
					// a statement at no range of the body's own code — a body spliced in, a macro's expansion — replaced the call
					// written between the statements of that code around it, which keep their order
					if (!own(ranges[i])) _site = between(exprs, ranges, i, site);
					walkAs(exprs[i], i == exprs.length - 1 ? use : Statement);
					_site = site;
				}
			case TIf(condition, then, otherwise):
				walk(condition);
				walkAs(then, use);
				if (otherwise != null) walkAs(otherwise, use);
			case TSwitch(subject, cases, otherwise):
				// the subject is only compared with the patterns; each arm is the switch's own value
				walkAs(subject, Compare);
				for (c in cases) {
					for (value in c.values) walk(value);
					walkAs(c.expr, use);
				}
				if (otherwise != null) walkAs(otherwise, use);
			case TTry(body, catches):
				walkAs(body, use);
				for (c in catches) walkAs(c.expr, use);
			case TParenthesis(inner) | TMeta(_, inner):
				walkAs(inner, use);
			case _:
				TypedExprTools.iter(e, walk);
		}
	}

	/**
	 * The method whose inlined call has the local `v`, declared at `p` in the block at `block`, for its receiver: the
	 * compiler binds a receiver that is more than a local or a constant to a local of its own, named
	 * `TypedFactsMacro.INLINED_RECEIVER` and declared at the spliced body's own range — the block holding it — in code
	 * spliced from a method no parameter of which takes that name (`InlineMethod.receiver`). A local the method's code
	 * declares stands at a statement inside that block. Null for any other local.
	 */
	private function receiverCall(v: TVar, p: Position, block: Null<Position>): Null<String> {
		final method: Null<InlineMethod> = _splice;
		if (method == null || block == null || !method.receiver || v.name != TypedFactsMacro.INLINED_RECEIVER) return null;
		final at: { min: Int, max: Int, file: String } = Context.getPosInfos(p);
		final around: { min: Int, max: Int, file: String } = Context.getPosInfos(block);
		if (at.file != around.file || at.min != around.min || at.max != around.max) return null;
		return method.id.substr(method.id.lastIndexOf('.') + 1);
	}

	/** Walk the receiver of a field access, its value used as `use`; a type named as one is no value, so it is not walked. */
	private function walkReceiver(receiver: TypedExpr, use: FactUse): Void {
		if (!receiver.expr.match(TTypeExpr(_))) walkAs(receiver, use);
	}

	/** A `Reflect.*` / `Type.*` member read as a value rather than called: whatever calls it later is reflection. */
	private function reflectionValue(fa: FieldAccess, e: TypedExpr): Void {
		switch fa {
			case FStatic(c, cf) | FClosure({ c: c }, cf) if (TypedFactsShapes.REFLECTION_CLASSES.contains(c.toString())):
				add('refl', '{"t":${q(c.toString() + '.' + cf.toString())},"v":true,"p":${at(e.pos)}}');
			case _:
		}
	}

	/**
	 * The instantiation the compiler chose for a field declaring type parameters of its own, read or called through `fa`
	 * as `applied`: its declared type and that one (`gens`), which say what each of its parameters stands for there.
	 */
	private function instantiated(fa: FieldAccess, applied: Type, p: Position): Void {
		final field: Null<ClassField> = switch fa {
			case FInstance(_, _, f) | FStatic(_, f) | FClosure(_, f): f.get();
			case _: null;
		};
		if (field != null && field.params.length > 0) add('gens', '{"d":${q(str(field.type))},"s":${q(str(applied))},"p":${at(p)}}');
	}

	/** `p` without its brackets, for a fact written as a flat array. */
	private function range(p: Position): String {
		final full: String = at(p);
		return full.substring(1, full.length - 1);
	}

	/** Each element of an array or structure literal `e` into the slot its type declares for it. */
	private function literalFlows(e: TypedExpr): Void {
		switch [e.expr, TypeTools.follow(e.t)] {
			case [TArrayDecl(items), TInst(_, [element])]:
				final sink: String = str(element);
				for (item in items) flowInto(item, sink, 'arr', item.pos);
			case [TObjectDecl(entries), TAnonymous(a)]:
				final declared: Array<ClassField> = a.get().fields;
				for (entry in entries) {
					final slot: Null<ClassField> = Lambda.find(declared, f -> f.name == entry.name);
					if (slot != null) flowInto(entry.expr, str(slot.type), 'obj', entry.expr.pos);
				}
			case _:
		}
	}

	/** A string conversion of `operand`, `x` when it is an object of exactly its own type (`exactObject`). */
	private function stringSite(operand: TypedExpr): Void {
		add('strs', '{"o":${q(str(operand.t))},"p":${at(operand.pos)}' + (exactObject(operand) ? ',"x":true}' : '}'));
	}

	/**
	 * Whether `e` yields an object built as an instance of exactly the class its type names: a construction, or a local
	 * initialized with one of its own type and never written again (`_built`).
	 */
	private function exactObject(e: TypedExpr): Bool {
		return switch e.expr {
			case TParenthesis(inner) | TMeta(_, inner): exactObject(inner);
			case TLocal(v):
				_built.exists(v.id) && !_written.exists(v.id);
			case _: constructed(e);
		};
	}

	/**
	 * Whether the exception wrapping throws `value` as it is, converting nothing (`haxe.Exception.thrown`): an object of
	 * exactly a class extending `haxe.Exception` (`exactObject`). A value only typed so may be any object at run time.
	 */
	private function thrownAsIs(value: TypedExpr): Bool {
		return exactObject(value) && TypedFactsShapes.isException(value.t);
	}

	/**
	 * Whether `e` yields a structure built where it is acted on: an object literal, or a local initialized with one and never
	 * written again (`_literals`), which holds that one object for as long as it lives — no instance of any class.
	 */
	private function freshStructure(e: TypedExpr): Bool {
		return switch e.expr {
			case TParenthesis(inner) | TMeta(_, inner): freshStructure(inner);
			case TLocal(v):
				_literals.exists(v.id) && !_written.exists(v.id);
			case _: objectLiteral(e);
		};
	}

	/** Whether `e` is an object literal, seen through parentheses and metadata. */
	private static function objectLiteral(e: TypedExpr): Bool {
		return switch e.expr {
			case TParenthesis(inner) | TMeta(_, inner): objectLiteral(inner);
			case TObjectDecl(_): true;
			case _: false;
		};
	}

	/** Whether `e` is a construction, seen through parentheses and metadata. */
	private static function constructed(e: TypedExpr): Bool {
		return switch e.expr {
			case TParenthesis(inner) | TMeta(_, inner): constructed(inner);
			case TNew(_, _, _): true;
			case _: false;
		};
	}

	/**
	 * The written side of an assignment: a field is a write (and a read too when `alsoRead`), an array element is a write
	 * through the array holding it, anything else is walked. `fresh`: the target alone holds the value stored.
	 */
	private function target(lhs: TypedExpr, alsoRead: Bool, fresh: Bool): Void {
		switch lhs.expr {
			case TField(receiver, fa):
				fieldFact(lhs, receiver, fa, true, fresh ? ',"fresh":true' : '');
				if (alsoRead) fieldFact(lhs, receiver, fa, false, ',' + useText(Update));
				walkReceiver(receiver, MemberWrite);
			case TArray(array, index):
				add('elems', '{"r":${q(str(array.t))},"rp":${at(array.pos)},"p":${at(lhs.pos)}}');
				walkAs(array, ElementWrite);
				walk(index);
			case TLocal(_) if (!alsoRead):
				// a write of the local, no use of the value it held
				walkAs(lhs, Assigned);
			case _:
				walk(lhs);
		}
	}

	/**
	 * The id of the local `lhs` writes when it is one this node declared (`_aliases`) and `rhs`, what it stores, a field's
	 * or a local's value as it is (`heldValue`); null otherwise.
	 */
	private function storedLocal(lhs: TypedExpr, rhs: TypedExpr): Null<Int> {
		if (!heldValue(rhs)) return null;
		return switch lhs.expr {
			case TLocal(v) if (_aliases[v.id]?.owner == id): v.id;
			case _: null;
		};
	}

	/**
	 * Whether `e` hands a field's or a local's value on AS IT IS, so the local initialized with it or assigned it holds that
	 * value: the read itself, or a VALUE-TRANSPARENT construct at least one of whose value positions does — parentheses,
	 * metadata, a block by its last expression (the typer wraps every branch of an if- or switch-expression in one), an
	 * `if` with an `else` (a ternary is one), a `switch`, a `try`. Those are exactly the constructs `visit`
	 * walks every value position of with the use it was handed, the condition, subject and patterns with their own, so a
	 * `Held` reaches a read in a branch and nothing else: `final l = if (c) items else null;` holds `items` as
	 * `l = items;` in a branch of a statement `if` does. Measured: without the block step the typed `if (c) items else null` is
	 * `TIf(c, TBlock([items]), TBlock([null]))` and the read stays a value. A positive list: a cast, a call, an operator or anything
	 * else hands on some other value, or one the facts cannot follow, and the read stays a value.
	 */
	private static function heldValue(e: TypedExpr): Bool {
		return switch e.expr {
			case TField(_, _) | TLocal(_): true;
			case TParenthesis(inner) | TMeta(_, inner):
				heldValue(inner);
			// the typer wraps every branch of an if- / switch-expression in a block whose last expression is its value
			case TBlock(exprs):
				exprs.length > 0 && heldValue(exprs[exprs.length - 1]);
			case TIf(_, then, otherwise):
				otherwise != null && (heldValue(then) || heldValue(otherwise));
			case TSwitch(_, cases, otherwise):
				var held: Bool = otherwise != null && heldValue(otherwise);
				for (c in cases) held = held || heldValue(c.expr);
				held;
			case TTry(body, catches):
				var held: Bool = heldValue(body);
				for (c in catches) held = held || heldValue(c.expr);
				held;
			case _: false;
		};
	}

	/**
	 * Record a read of the local `v`, whose value `alias` holds, used as `use`: a read from a nested function captures the
	 * value; one stored in another local of this node (`Held`) is used as that local's reads are (`Alias.links`); a write
	 * is no use; and the receiver an inline method of no parameter was spliced in with (`substitutedReceiver`) is the
	 * receiver of a call of that method, as `receiverCall`'s is.
	 */
	private function localRead(alias: Alias, v: TVar, use: FactUse, substituted: Null<InlineMethod>): Void {
		// a nested function holds the local, so the value goes wherever that function goes
		if (alias.owner != id) {
			aliasUse(alias, Value);
			return;
		}
		switch use {
			case Held(other) if (_aliases[other]?.owner == id):
				if (!alias.links.contains(other)) alias.links.push(other);
			case Assigned:
			case _:
				final method: Null<String> = substitutedReceiver(v, substituted);
				aliasUse(alias, method == null ? use : Call(method));
		}
	}

	/**
	 * The method an inlined call of which had the local `v` for its receiver, read directly under that method's spliced code
	 * (`substituted`): one declaring no parameter, so that no value of the call site but its receiver reaches its body, of
	 * the class of `v`'s type; null otherwise.
	 */
	private static function substitutedReceiver(v: TVar, substituted: Null<InlineMethod>): Null<String> {
		if (substituted == null || substituted.arity != 0) return null;
		final dot: Int = substituted.id.lastIndexOf('.');
		final name: String = substituted.id.substr(dot + 1);
		return switch TypeTools.followWithAbstracts(v.t) {
			case TInst(c, _) if (TypedFactsMacro.typeId(c.get().pack, c.get().name) == substituted.id.substr(0, dot)): name;
			case _: null;
		};
	}

	/** The uses of the value the local `local` holds: its reads', and those of every local it is stored in, in turn. */
	private function aliasUses(local: Int): Array<String> {
		final out: Array<String> = [];
		final pending: Array<Int> = [local];
		final seen: Array<Int> = [];
		while (pending.length > 0) {
			final next: Int = pending.pop() ?? local;
			if (seen.contains(next)) continue;
			seen.push(next);
			final alias: Null<Alias> = _aliases[next];
			if (alias == null) continue;
			for (u in alias.uses) if (!out.contains(u)) out.push(u);
			for (l in alias.links) pending.push(l);
		}
		return out;
	}

	/** Record a field access: `tail` ends its fact with how a read value is used, or what a write stores. */
	private function fieldFact(e: TypedExpr, receiver: TypedExpr, fa: FieldAccess, write: Bool, tail: String): Void {
		add('fields', fieldHead(e, receiver, fa, write) + tail + '}');
	}

	/** The fact of a field access up to its closing brace. */
	private function fieldHead(e: TypedExpr, receiver: TypedExpr, fa: FieldAccess, write: Bool): String {
		final access: FieldRef = TypedFactsShapes.describe(fa);
		final declaring: Null<String> = access.owner;
		final owned: String = declaring == null ? '' : ',"o":${q(declaring)}';
		final written: String = write ? ',"w":true' : '';
		return '{"f":${q(access.field)},"a":"${access.kind}"$owned,"r":${q(str(receiver.t))},"t":${q(str(e.t))},"p":${at(e.pos)}$written';
	}

	private function call(e: TypedExpr, callee: TypedExpr, args: Array<TypedExpr>): Void {
		argFlows(callee.t, args);
		final where: String = at(e.pos);
		final head: String = '"rt":${q(str(e.t))},"p":$where' + dynamicOperand(callee.t, args);
		// the method a declared field names, whose parameters take the arguments: its own facts follow each (`Argument`)
		var handedTo: Null<String> = null;
		var handedVia: String = '';
		final fact: String = switch callee.expr {
			case TField(receiver, fa):
				final access: FieldRef = TypedFactsShapes.describe(fa);
				final declaring: Null<String> = access.owner;
				final targetName: String = declaring == null ? access.field : '$declaring.${access.field}';
				if (access.kind == 'FStatic' && declaring != null && TypedFactsShapes.REFLECTION_CLASSES.contains(declaring))
					reflection(targetName, args, where);
				if (access.kind == 'FStatic' && declaring != null && TypedFactsShapes.SYNTAX_CLASSES.contains(declaring)) {
					final code: String = TypedFactsShapes.nativeCode(args, TypedFactsShapes.SYNTAX_CODE_MEMBERS.contains(access.field));
					add('native', '{"w":"syntax","n":${q(targetName)},"p":$where$code${handedText(args)}}');
				}
				final chained: Bool = nativeChain(callee, args);
				walkReceiver(receiver, Call(access.field));
				if (chained) _nativeChain = null;
				instantiated(fa, callee.t, callee.pos);
				switch fa {
					case FInstance(c, _, cf) | FStatic(c, cf):
						handed(c.get(), cf.get(), targetName, args);
					case _:
				}
				final kind: String = calledKind(fa, targetName, access.kind);
				if (
					declaring != null && kind == access.kind && DECLARED_CALLS.contains(kind)
					&& !TypedFactsShapes.REFLECTION_CLASSES.contains(declaring) && !TypedFactsShapes.SYNTAX_CLASSES.contains(declaring)
				) {
					handedTo = targetName;
					handedVia = kind;
				}
				final chosen: String = _host.overloaded(targetName) ? ',"sig":${q(str(callee.t))}' : '';
				'{"t":${q(targetName)},"a":"$kind"$chosen,"r":${q(str(receiver.t))},"rp":${at(receiver.pos)},$head}';
			case TConst(TSuper):
				final sup: String = switch TypeTools.follow(callee.t) {
					case TInst(c, _):
						final ctor: Null<Ref<ClassField>> = c.get().constructor;
						if (ctor != null) handed(c.get(), ctor.get(), c.toString() + '.new', args);
						',"t":' + q(c.toString() + '.new');
					case _: '';
				};
				'{"a":"super"$sup,$head}';
			case TLocal(v) if (_locals.exists(v.id)):
				'{"t":${q(_locals[v.id] ?? '')},"a":"local",$head}';
			case TIdent(identifier):
				final code: String = TypedFactsShapes.nativeCode(args, TypedFactsShapes.CODE_INTRINSICS.contains(identifier));
				add('native', '{"w":"ident","n":${q(identifier)},"p":$where$code${handedText(args)}}');
				'{"t":${q(identifier)},"a":"ident",$head}';
			case _:
				walk(callee);
				'{"a":"value","r":${q(str(callee.t))},"rp":${at(callee.pos)},$head}';
		};
		add('calls', fact);
		final to: Null<String> = handedTo;
		final declared: Null<Array<{ name: String, opt: Bool, t: Type }>> = parametersOf(callee.t);
		var handed: Bool = to != null && declared != null;
		for (i in 0...args.length) {
			// a rest parameter takes the arguments into an array the compiler builds, which no parameter use follows
			if (declared == null || i >= declared.length || TypedFactsShapes.restElement(declared[i].t) != null) handed = false;
			if (handed && to != null)
				walkAs(args[i], Argument(to, handedVia, i))
			else
				walk(args[i]);
		}
	}

	/**
	 * The access kind a call through `fa` is recorded under: a field whose value can be replaced — a variable of a
	 * function type, a `dynamic` method — is `fieldValue`, since it calls whatever the field holds, not the declared body.
	 */
	private function calledKind(fa: FieldAccess, targetName: String, kind: String): String {
		final cf: Null<Ref<ClassField>> = switch fa {
			case FInstance(_, _, f) | FStatic(_, f): f;
			case _: null;
		};
		if (cf == null) return kind;
		return _host.replaceable(targetName, cf) ? 'fieldValue' : kind;
	}

	private function reflection(targetName: String, args: Array<TypedExpr>, where: String): Void {
		var literal: String = '';
		var named: String = '';
		for (a in args) switch a.expr {
			case TConst(TString(s)) if (literal == ''):
				literal = ',"n":' + Json.stringify(s);
			case TTypeExpr(m) if (named == ''):
				named = ',"c":' + q(TypedFactsShapes.moduleTypeId(m));
			case _:
		}
		final first: Null<TypedExpr> = args.length > 0 ? args[0] : null;
		final receiver: String = first == null
			? ''
			: ',"r":${q(sourceType(first))}' + (exactObject(first) ? ',"x":true' : '') + (isThis(first) ? ',"h":true' : '') + (
				freshStructure(first) ? ',"o":true' : ''
			);
		add('refl', '{"t":${q(targetName)}$literal$named$receiver,"p":$where}');
	}

	/**
	 * Start the field chain `e` when it is rooted at a native identifier and no chain is being walked (`_nativeChain`): the
	 * identifier is then recorded with the chain as its code, handed `args`. Whether it started one, which the caller ends.
	 */
	private function nativeChain(e: TypedExpr, args: Array<TypedExpr>): Bool {
		if (_nativeChain != null) return false;
		final root: Null<TypedExpr> = TypedFactsShapes.nativeRoot(e);
		if (root == null) return false;
		_nativeChain = { root: root, text: TypedFactsShapes.chainText(e), handed: args };
		return true;
	}

	/**
	 * The types of the values `args` hands target code, each value of a branching expression apart (`collectLeaves`), as a
	 * `h` field; empty for none.
	 */
	private function handedText(args: Array<TypedExpr>): String {
		final leaves: Array<TypedExpr> = [];
		for (a in args) TypedFactsShapes.collectLeaves(a, leaves);
		return leaves.length == 0 ? '' : ',"h":[${[for (leaf in leaves) q(sourceType(leaf))].join(',')}]';
	}

	/**
	 * Each argument into its parameter: a rest parameter takes every remaining argument at its element type, and a callee
	 * of no function type — `Dynamic`, a native identifier — takes every argument as `Dynamic`.
	 */
	private function argFlows(fnType: Null<Type>, args: Array<TypedExpr>): Void {
		final params: Null<Array<{ name: String, opt: Bool, t: Type }>> = parametersOf(fnType);
		if (params == null) {
			for (a in args) flowInto(a, 'Dynamic', 'arg', a.pos);
			return;
		}
		var rest: Null<String> = null;
		for (i in 0...args.length) {
			if (rest == null && i < params.length) {
				final element: Null<Type> = TypedFactsShapes.restElement(params[i].t);
				if (element != null) rest = str(element);
			}
			final sink: Null<String> = rest ?? (i < params.length ? str(params[i].t) : null);
			if (sink != null) flowInto(args[i], sink, 'arg', args[i].pos);
		}
	}

	/**
	 * Each argument handed to `field` of the extern class `cls` (`target`): target code, which no fact describes. One
	 * fact per value-producing leaf, at the type the field declares for its parameter — a rest parameter's element type
	 * for every remaining argument — with the extern's own type parameters unapplied.
	 */
	private function handed(cls: ClassType, field: ClassField, target: String, args: Array<TypedExpr>): Void {
		if (!cls.isExtern) return;
		final params: Null<Array<{ name: String, opt: Bool, t: Type }>> = switch TypeTools.follow(field.type) {
			case TFun(declared, _): declared;
			case _: null;
		};
		var rest: Null<String> = null;
		for (i in 0...args.length) {
			if (params != null && rest == null && i < params.length) {
				final element: Null<Type> = TypedFactsShapes.restElement(params[i].t);
				if (element != null) rest = str(element);
			}
			final written: String = rest ?? (params != null && i < params.length ? str(params[i].t) : 'Dynamic');
			final declared: String = written == '?' ? 'Dynamic' : written;
			final leaves: Array<TypedExpr> = [];
			TypedFactsShapes.collectLeaves(args[i], leaves);
			for (leaf in leaves) add('hands', '{"t":${q(target)},"s":${q(sourceType(leaf))},"d":${q(declared)},"p":${at(leaf.pos)}}');
		}
	}

	/** Record `use` as one of the uses of the value `alias` holds. */
	private static function aliasUse(alias: Alias, use: FactUse): Void {
		final text: String = useText(use);
		if (!alias.uses.contains(text)) alias.uses.push(text);
	}

	/** `use` as the keys of a field read's fact: `u`, and `m` for a call. */
	private static function useText(use: FactUse): String {
		return switch use {
			case Call(method): '"u":"call","m":${q(method)}';
			case Index: '"u":"index"';
			case ElementWrite: '"u":"elemWrite"';
			case Member: '"u":"member"';
			case MemberWrite: '"u":"memberWrite"';
			case Compare: '"u":"compare"';
			case Iterable: '"u":"iter"';
			case Update: '"u":"update"';
			case Argument(target, access, index): '"u":"value","ag":${q(target)},"aa":"$access","ai":$index';
			case Value | Statement | Held(_) | Assigned: '"u":"value"';
		};
	}

	private static inline function str(t: Null<Type>): String {
		return TypedFactsMacro.typeString(t, 0);
	}

	private static inline function q(s: String): String {
		return TypedFactsMacro.q(s);
	}

	/**
	 * The first argument of a call handing it to a `Dynamic` parameter, as the call fact's `o` — its type — and `x` — an
	 * object of exactly its class (`exactObject`); empty for any other call. A value handed to a parameter of no type records
	 * no flow when it has none either (`flowText`), and the argument of a call an inlined body spliced in lies in the text of
	 * the method it came from, so nothing else says what the call was handed.
	 */
	private function dynamicOperand(fnType: Null<Type>, args: Array<TypedExpr>): String {
		final params: Null<Array<{ name: String, opt: Bool, t: Type }>> = parametersOf(fnType);
		final first: Null<TypedExpr> = args.length > 0 ? args[0] : null;
		if (params == null || params.length == 0 || first == null || str(params[0].t) != 'Dynamic') return '';
		return ',"o":${q(sourceType(first))}' + (exactObject(first) ? ',"x":true' : '');
	}

	/** The type the abstract `t` wraps, at its arguments — what its value is at run time; null for any other type and a core type. */
	private static function wrapped(t: Type): Null<Type> {
		return switch TypeTools.follow(t) {
			case TAbstract(a, params):
				// read once per abstract: each `a.get()` decodes the whole abstract, and a TM build asks ~47k times (11% of the macro)
				final key: String = a.toString();
				if (!abstractBodies.exists(key)) {
					final read: AbstractType = a.get();
					abstractBodies[key] = read.meta.has(':coreType') ? null : { type: read.type, params: read.params };
				}
				final body: Null<{ type: Type, params: Array<TypeParameter> }> = abstractBodies[key];
				body == null ? null : TypeTools.applyTypeParameters(body.type, body.params, params);
			case _: null;
		};
	}

	/** The parameters a callee of type `fnType` declares; null for no function type. */
	private static function parametersOf(fnType: Null<Type>): Null<Array<{ name: String, opt: Bool, t: Type }>> {
		return fnType == null
			? null
			: switch TypeTools.follow(fnType) {
				case TFun(declared, _): declared;
				case _: null;
			};
	}

	/** Whether `e` is `this`, seen through parentheses and metadata. */
	private static function isThis(e: TypedExpr): Bool {
		return switch e.expr {
			case TParenthesis(inner) | TMeta(_, inner): isThis(inner);
			case TConst(TThis): true;
			case _: false;
		};
	}

}
/** How the value an expression produces is used where it is read: what a field read's `u` records (`TypedFactsProbe`). */
private enum FactUse {

	/** Anything the other constructors do not name — an argument, a stored or returned value — and a capture. */
	Value;

	/** Discarded: a statement's own value. */
	Statement;

	/** The receiver of a call of its field `method`, or of an inlined call of it (`TypedFactsWalk.receiverCall`). */
	Call(method: String);

	/** An array indexed to read an element. */
	Index;

	/** An array indexed to write an element: `a[i] = v`, `a[i] += v`, `a[i]++`. */
	ElementWrite;

	/** The receiver of a field read that is no method closure. */
	Member;

	/** The receiver of a field write. */
	MemberWrite;

	/** An operand of a comparison, or a `switch` subject. */
	Compare;

	/** The iterated value of a `for` the compiler kept. */
	Iterable;

	/** A field read by a compound assignment or an increment of that field, the read half of its write. */
	Update;

	/** The initializer of the local `id`, or a value an assignment statement stores in it: the local's reads are the uses. */
	Held(id: Int);

	/** The local an assignment writes: no use of the value it held. */
	Assigned;

	/**
	 * The `index`-th argument of a call of the method `target` through the field access `access` (`FStatic`, `FInstance`):
	 * the value goes to that parameter, which the method's own facts follow (`pu`). Recorded as a `value` use, so a reader
	 * that does not follow the parameter keeps reading an escape.
	 */
	Argument(target: String, access: String, index: Int);
}

/**
 * A local a `var` declares: the node that declared it, the uses its reads made, as `useText`,
 * and the locals of that node a read of it was stored in, whose reads are uses of its value too.
 */
private typedef Alias = {
	final owner: String;
	final uses: Array<String>;
	final links: Array<Int>;
}
/** A field chain rooted at a native identifier (`TypedFactsWalk.nativeChain`): the identifier, its text, what a call through it hands. */
private typedef NativeChain = {
	final root: TypedExpr;
	final text: String;
	final handed: Array<TypedExpr>;
}
#end

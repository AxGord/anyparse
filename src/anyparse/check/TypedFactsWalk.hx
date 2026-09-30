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
		'params', 'calls', 'news', 'fields', 'elems', 'flows', 'strs', 'iters', 'refl', 'native', 'vars', 'reads', 'fns'
	];

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
	 * The locals initialized straight from a field read, shared with the nested walks: each read of one is a use of the
	 * field's value, so the read is recorded once the uses are known. A read from a nested function captures the value.
	 */
	private final _aliases: Map<Int, Alias>;

	/** The field reads held back until their local's uses are known: the fact without its use, and the local. */
	private final _deferred: Array<{ fact: String, local: Int }> = [];

	/** How the value of the expression `walk` is about to visit is used; `visit` takes it and resets it to `Value`. */
	private var _use: FactUse = Value;

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

	/** Extra header fields: `gen`, `gi`, `inl`, `ov`. */
	private var _header: String = '';

	public function new(
		host: TypedFactsMacro, id: String, kind: String, owner: String, isStatic: Bool, signature: String, name: Null<String>,
		locals: Map<Int, String>, written: Map<Int, Bool>, aliases: Map<Int, Alias>
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
				for (a in f.args) add('params', '{"n":${q(a.v.name)},"t":${q(localType(a.v))}}');
				// a function's body is never its value: a returned value is the operand of a `return`
				walkAs(f.expr, Statement);
			case _:
				walk(e);
		}
		for (d in _deferred) {
			final seen: Array<String> = _aliases[d.local]?.uses ?? [];
			// a local never read is answered as any use the walk does not name
			final uses: Array<String> = seen.length > 0 ? seen : [useText(Value)];
			for (u in uses) add('fields', d.fact + ',' + u + '}');
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

	/** `p` as a fact position: `[min,max]` in the node's file, else `[i,min,max]`. */
	private function at(p: Position): String {
		final info: { min: Int, max: Int, file: String } = Context.getPosInfos(p);
		if (info.file == _home) return '[${info.min},${info.max}]';
		if (_host.reflectionModule(info.file)) incomplete('reflection-inlined');
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
			flowText(sourceType(value), sink, how, p);
		else
			for (leaf in leaves) flowText(sourceType(leaf), sink, how, leaf.pos);
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

	/** A value of type `s` reaching a place of type `d`, kept only when the two differ beyond nullability. */
	private function flowText(s: String, d: String, how: String, p: Position): Void {
		if (how != 'cast' && FactsTypeText.unwrapNull(s) == FactsTypeText.unwrapNull(d)) return;
		add('flows', '{"s":${q(s)},"d":${q(d)},"c":"$how","p":${at(p)}}');
	}

	private function child(f: TypedExpr, localName: Null<String>): String {
		final info: { min: Int, max: Int, file: String } = Context.getPosInfos(f.pos);
		final nested: TypedFactsWalk = new TypedFactsWalk(
			_host, '$id@${info.min}', localName == null ? 'fn' : 'local', _owner, _isStatic, str(f.t), localName, _locals, _written,
			_aliases
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
	 * inlined constant, at its declaration. So is a range that meets the body without lying inside it: the compiler's
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
		final code: Bool = !e.expr.match(TConst(_) | TTypeExpr(_));
		if (inside)
			_site = { min: info.min, max: info.max }
		else if (straddles)
			_site = { min: _min, max: _max };
		if (inside || straddles)
			_splice = null
		else if (saved && code)
			spliced(e, info)
		else if (splice != null && code && !(info.file == splice.file && info.min >= splice.min && info.max <= splice.max))
			nestedSplice(e, info);
		// back inside, as the call site's own arguments are: a further splice there is a call of its own
		_inBody = inside || straddles;
		visit(e);
		_inBody = saved;
		_site = site;
		_splice = splice;
	}

	/** Walk `e`, whose value is used as `use`. */
	private function walkAs(e: TypedExpr, use: FactUse): Void {
		_use = use;
		walk(e);
	}

	/**
	 * Record the spliced body rooted at `e`: the call of the method it came from — `inline`, or inlined by its call site — found at the root or, when
	 * the root carries a position of its own — an abstract's `this` stands at the whole abstract — at the first
	 * expression under it that lies in one; `macro-expansion` when none does. The call carries where it ran, the range
	 * of the innermost expression of the body around it (`_site`), and the method's declared range, which holds its code.
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
			return;
		}
		inlinedCall(callee, e.t, at(e.pos));
	}

	/**
	 * A spliced body walked below the one of `_splice` that is none of its method's code: a body that method's code spliced
	 * in turn, run at the same site. Code no method holds stays the outer body's.
	 */
	private function nestedSplice(e: TypedExpr, info: { min: Int, max: Int, file: String }): Void {
		final callee: Null<InlineMethod> = _host.inlineCallee(info.file, info.min, info.max);
		if (callee != null) inlinedCall(callee, e.t, at(e.pos));
	}

	/**
	 * The call of `callee`, whose body was spliced in at `where` with the result type `result`: the current site (`s`) and
	 * the method's declared range (`d`). What is walked below it is that method's.
	 */
	private function inlinedCall(callee: InlineMethod, result: Type, where: String): Void {
		final declared: String = _host.range(callee.file, callee.min, callee.max, _home);
		add('calls', '{"t":${q(callee.id)},"a":"inlined","rt":${q(str(result))},"p":$where,"s":[${_site.min},${_site.max}],"d":$declared}');
		_splice = callee;
	}

	private function visit(e: TypedExpr): Void {
		// noqa: complexity
		final use: FactUse = _use;
		_use = Value;
		final block: Null<Position> = _block;
		_block = null;
		switch e.expr {
			case TFunction(_):
				child(e, null);
			case TLocal(v):
				if (!v.name.startsWith('`')) add('reads', '[${range(e.pos)},${q(localType(v))}]');
				final alias: Null<Alias> = _aliases[v.id];
				// a nested function holds the local, so the value goes wherever that function goes
				if (alias != null) aliasUse(alias, alias.owner == id ? use : Value);
			case TIdent(identifier):
				add('native', '{"w":"ident","n":${q(identifier)},"p":${at(e.pos)}}');
			case TTypeExpr(m):
				// a reflection class read as a value takes every one of its members along
				final name: String = TypedFactsShapes.moduleTypeId(m);
				if (TypedFactsShapes.REFLECTION_CLASSES.contains(name)) add('refl', '{"t":${q(name)},"v":true,"p":${at(e.pos)}}');
			case TVar(v, init):
				declare(v, e.pos);
				if (init != null) {
					flowInto(init, str(v.t), 'var', e.pos);
					final called: Null<String> = receiverCall(v, e.pos, block);
					switch init.expr {
						case TFunction(_):
							final made: String = child(init, v.name);
							if (!_written.exists(v.id)) _locals[v.id] = made;
						case _ if (called != null):
							// the receiver of an inlined call: what the method's code then does with it is the call's
							walkAs(init, Call(called));
						case TField(_, _):
							// the field's value goes wherever the local's reads take it: the compiler holds a lowered loop's
							// array, and the receiver of a compound element write, in a local of its own. An unrolled loop
							// declares one local once per copy, and every copy's reads are its uses
							final alias: Alias = _aliases[v.id] ?? { owner: id, uses: [] };
							_aliases[v.id] = alias;
							walkAs(init, Held(v.id));
						case _:
							walk(init);
					}
				}
			case TCall(callee, args):
				call(e, callee, args);
			case TNew(c, params, args):
				add('news', '{"t":${q(c.toString())},"ty":${q(str(e.t))},"p":${at(e.pos)}}');
				final cls: ClassType = c.get();
				final ctor: Null<Ref<ClassField>> = cls.constructor;
				if (ctor != null) argFlows(TypeTools.applyTypeParameters(ctor.get().type, cls.params, params), args);
				for (a in args) walk(a);
			case TField(receiver, fa):
				switch use {
					case Held(local):
						_deferred.push({ fact: fieldHead(e, receiver, fa, false), local: local });
					case _:
						fieldFact(e, receiver, fa, false, ',' + useText(use));
				}
				reflectionValue(fa, e);
				// a method closure holds its receiver; any other field access reads through it
				walkReceiver(receiver, fa.match(FClosure(_, _)) ? Value : Member);
			case TArray(array, index):
				walkAs(array, Index);
				walk(index);
			case TBinop(OpAssign, lhs, rhs):
				flowInto(rhs, str(lhs.t), 'assign', e.pos);
				// a fresh value stored by an assignment whose own value goes nowhere is held by its target alone
				target(lhs, false, use == Statement && TypedFactsShapes.isFresh(rhs));
				walk(rhs);
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
				// every statement but the last is discarded; the last is the block's own value
				for (i in 0...exprs.length) {
					_block = e.pos;
					walkAs(exprs[i], i == exprs.length - 1 ? use : Statement);
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

	private function stringSite(operand: TypedExpr): Void {
		add('strs', '{"o":${q(str(operand.t))},"p":${at(operand.pos)}}');
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
			case _:
				walk(lhs);
		}
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
		final head: String = '"rt":${q(str(e.t))},"p":$where';
		final fact: String = switch callee.expr {
			case TField(receiver, fa):
				final access: FieldRef = TypedFactsShapes.describe(fa);
				final declaring: Null<String> = access.owner;
				final targetName: String = declaring == null ? access.field : '$declaring.${access.field}';
				if (access.kind == 'FStatic' && declaring != null && TypedFactsShapes.REFLECTION_CLASSES.contains(declaring))
					reflection(targetName, args, where);
				if (access.kind == 'FStatic' && declaring != null && TypedFactsShapes.SYNTAX_CLASSES.contains(declaring))
					add('native', '{"w":"syntax","n":${q(targetName)},"p":$where}');
				walkReceiver(receiver, Call(access.field));
				final kind: String = calledKind(fa, targetName, access.kind);
				final chosen: String = _host.overloaded(targetName) ? ',"sig":${q(str(callee.t))}' : '';
				'{"t":${q(targetName)},"a":"$kind"$chosen,"r":${q(str(receiver.t))},"rp":${at(receiver.pos)},$head}';
			case TConst(TSuper):
				final sup: String = switch TypeTools.follow(callee.t) {
					case TInst(c, _): ',"t":' + q(c.toString() + '.new');
					case _: '';
				};
				'{"a":"super"$sup,$head}';
			case TLocal(v) if (_locals.exists(v.id)):
				'{"t":${q(_locals[v.id] ?? '')},"a":"local",$head}';
			case TIdent(identifier):
				add('native', '{"w":"ident","n":${q(identifier)},"p":$where}');
				'{"t":${q(identifier)},"a":"ident",$head}';
			case _:
				walk(callee);
				'{"a":"value","r":${q(str(callee.t))},"rp":${at(callee.pos)},$head}';
		};
		add('calls', fact);
		for (a in args) walk(a);
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
		add('refl', '{"t":${q(targetName)}$literal$named,"p":$where}');
	}

	/**
	 * Each argument into its parameter: a rest parameter takes every remaining argument at its element type, and a callee
	 * of no function type — `Dynamic`, a native identifier — takes every argument as `Dynamic`.
	 */
	private function argFlows(fnType: Null<Type>, args: Array<TypedExpr>): Void {
		final params: Null<Array<{ name: String, opt: Bool, t: Type }>> = fnType == null
			? null
			: switch TypeTools.follow(fnType) {
				case TFun(declared, _): declared;
				case _: null;
			};
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
			case Value | Statement | Held(_): '"u":"value"';
		};
	}

	private static inline function str(t: Null<Type>): String {
		return TypedFactsMacro.typeString(t, 0);
	}

	private static inline function q(s: String): String {
		return TypedFactsMacro.q(s);
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

	/** The initializer of the local `id`: the local's reads are the uses. */
	Held(id: Int);
}

/** A local initialized from a field read: the node that declared it, and the uses its reads made, as `useText`. */
private typedef Alias = {
	final owner: String;
	final uses: Array<String>;
}
#end

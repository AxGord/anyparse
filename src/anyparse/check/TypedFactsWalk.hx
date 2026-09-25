package anyparse.check;

#if macro
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
		'params', 'calls', 'news', 'fields', 'flows', 'strs', 'iters', 'refl', 'native', 'vars', 'reads', 'fns'
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

	private var _ret: Null<Type> = null;
	private var _home: String = '';

	/** The body's range in `_home`: an expression outside it was spliced in by inlining or a macro. */
	private var _min: Int = 0;

	private var _max: Int = 0;

	/** Whether the innermost walked expression lies in the body's own range. */
	private var _inBody: Bool = true;

	/** Extra header fields: `gen`, `gi`, `inl`, `ov`. */
	private var _header: String = '';

	public function new(
		host: TypedFactsMacro, id: String, kind: String, owner: String, isStatic: Bool, signature: String, name: Null<String>,
		locals: Map<Int, String>, written: Map<Int, Bool>
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
		_host.noteHome(_home);
		final at: String = '[$_min,$_max]';
		switch e.expr {
			case TFunction(f):
				_ret = f.t;
				for (a in f.args) add('params', '{"n":${q(a.v.name)},"t":${q(localType(a.v))}}');
				walk(f.expr);
			case _:
				walk(e);
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
		if (how != 'cast' && TypedFactsShapes.unwrapNull(s) == TypedFactsShapes.unwrapNull(d)) return;
		add('flows', '{"s":${q(s)},"d":${q(d)},"c":"$how","p":${at(p)}}');
	}

	private function child(f: TypedExpr, localName: Null<String>): String {
		final info: { min: Int, max: Int, file: String } = Context.getPosInfos(f.pos);
		final nested: TypedFactsWalk = new TypedFactsWalk(
			_host, '$id@${info.min}', localName == null ? 'fn' : 'local', _owner, _isStatic, str(f.t), localName, _locals, _written
		);
		// a function outside this body was spliced in: it runs here, but no range of its own file is where it runs. One
		// bound straight to a local is reached without `walk`, so the splice is decided here too
		final inside: Bool = info.file == _home && info.min >= _min && info.max <= _max;
		if (_inBody && !inside) spliced(f, info);
		if (!_inBody || !inside) nested._header += ',"inl":${q(id)}';
		add('fns', q(nested.id));
		nested.root(f);
		return nested.id;
	}

	/**
	 * Walk `e`. The first expression outside the body's own range — another file, or elsewhere in this one — is the root of
	 * a spliced body: an inlined function, or a macro's expansion. The compiler keeps no range for the call site it
	 * replaced, so the node says where it cannot: `inline-site-unknown`, and `macro-expansion` when no inline function
	 * holds the spliced code. A constant or a type expression is left out: the compiler places a default argument's
	 * value, or an inlined constant, at its declaration.
	 */
	private function walk(e: TypedExpr): Void {
		final info: { min: Int, max: Int, file: String } = Context.getPosInfos(e.pos);
		final inside: Bool = info.file == _home && info.min >= _min && info.max <= _max;
		final saved: Bool = _inBody;
		if (saved && !inside && !e.expr.match(TConst(_) | TTypeExpr(_))) spliced(e, info);
		// back inside, as the call site's own arguments are: a further splice there is a call of its own
		_inBody = inside;
		visit(e);
		_inBody = saved;
	}

	/**
	 * Record the spliced body rooted at `e`: the call of the `inline` function it came from, found at the root or, when
	 * the root carries a position of its own — an abstract's `this` stands at the whole abstract — at the first
	 * expression under it that lies in one; `macro-expansion` when none does.
	 */
	private function spliced(e: TypedExpr, info: { min: Int, max: Int, file: String }): Void {
		incomplete('inline-site-unknown');
		var callee: Null<String> = _host.inlineCallee(info.file, info.min, info.max);
		if (callee == null) {
			final pending: Array<TypedExpr> = [];
			TypedExprTools.iter(e, x -> pending.push(x));
			while (callee == null && pending.length > 0) {
				final next: TypedExpr = pending.shift() ?? e;
				final at: { min: Int, max: Int, file: String } = Context.getPosInfos(next.pos);
				callee = _host.inlineCallee(at.file, at.min, at.max);
				if (callee == null) TypedExprTools.iter(next, x -> pending.push(x));
			}
		}
		if (callee == null) {
			incomplete('macro-expansion');
			return;
		}
		add('calls', '{"t":${q(callee)},"a":"inlined","rt":${q(str(e.t))},"p":${at(e.pos)}}');
	}

	private function visit(e: TypedExpr): Void {
		switch e.expr {
			case TFunction(_):
				child(e, null);
			case TLocal(v):
				if (!v.name.startsWith('`')) add('reads', '[${range(e.pos)},${q(localType(v))}]');
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
					switch init.expr {
						case TFunction(_):
							final made: String = child(init, v.name);
							if (!_written.exists(v.id)) _locals[v.id] = made;
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
				fieldFact(e, receiver, fa, false);
				reflectionValue(fa, e);
				walkReceiver(receiver);
			case TBinop(OpAssign, lhs, rhs):
				flowInto(rhs, str(lhs.t), 'assign', e.pos);
				target(lhs, false);
				walk(rhs);
			case TBinop(OpAssignOp(op), lhs, rhs):
				if (op == OpAdd && TypedFactsShapes.isString(lhs.t) && !TypedFactsShapes.isString(rhs.t)) stringSite(rhs);
				target(lhs, true);
				walk(rhs);
			case TUnop(OpIncrement | OpDecrement, _, operand):
				target(operand, true);
			case TBinop(OpAdd, a, b) if (TypedFactsShapes.isString(e.t)):
				for (operand in [a, b]) if (!TypedFactsShapes.isString(operand.t)) stringSite(operand);
				walk(a);
				walk(b);
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
				walk(it);
				walk(body);
			case _:
				TypedExprTools.iter(e, walk);
		}
	}

	/** Walk the receiver of a field access; a type named as one is no value, so it is not walked. */
	private function walkReceiver(receiver: TypedExpr): Void {
		if (!receiver.expr.match(TTypeExpr(_))) walk(receiver);
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

	/** The written side of an assignment: a field is a write (and a read too when `alsoRead`), anything else is walked. */
	private function target(lhs: TypedExpr, alsoRead: Bool): Void {
		switch lhs.expr {
			case TField(receiver, fa):
				fieldFact(lhs, receiver, fa, true);
				if (alsoRead) fieldFact(lhs, receiver, fa, false);
				walkReceiver(receiver);
			case _:
				walk(lhs);
		}
	}

	private function fieldFact(e: TypedExpr, receiver: TypedExpr, fa: FieldAccess, write: Bool): Void {
		final access: FieldRef = TypedFactsShapes.describe(fa);
		final declaring: Null<String> = access.owner;
		final owned: String = declaring == null ? '' : ',"o":${q(declaring)}';
		final written: String = write ? ',"w":true' : '';
		add(
			'fields',
			'{"f":${q(access.field)},"a":"${access.kind}"$owned,"r":${q(str(receiver.t))},"t":${q(str(e.t))},"p":${at(e.pos)}$written}'
		);
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
				walkReceiver(receiver);
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

	private static inline function str(t: Null<Type>): String {
		return TypedFactsMacro.typeString(t, 0);
	}

	private static inline function q(s: String): String {
		return TypedFactsMacro.q(s);
	}

}
#end

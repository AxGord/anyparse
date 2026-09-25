package anyparse.check;

#if macro
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

	private static final SYNTAX_CLASSES: Array<String> = [
		'js.Syntax',
		'cpp.Syntax',
		'python.Syntax',
		'php.Syntax',
		'lua.Syntax',
		'hl.Syntax',
		'cs.Syntax',
		'java.Syntax',
		'eval.Syntax'
	];

	/** The categories of a node line, in the order they are written. */
	private static final CATEGORIES: Array<String> = [
		'params', 'calls', 'news', 'fields', 'flows', 'strs', 'iters', 'refl', 'native', 'vars', 'reads', 'fns'
	];

	public final id: String;

	private final _facts: Map<String, Array<String>> = [];
	private final _seen: Map<String, Bool> = [];

	/** The type string of each local by id, rendered once: a local is read far more often than declared. */
	private final _localTypes: Map<Int, String> = [];

	private final _host: TypedFactsMacro;
	private final _kind: String;
	private final _owner: String;
	private final _isStatic: Bool;
	private final _signature: String;
	private final _name: Null<String>;
	private final _locals: Map<Int, String>;

	private var _ret: Null<Type> = null;
	private var _home: String = '';

	public function new(
		host: TypedFactsMacro, id: String, kind: String, owner: String, isStatic: Bool, signature: String, name: Null<String>,
		locals: Map<Int, String>
	) {
		this._host = host;
		this.id = host.uniqueId(id);
		this._kind = kind;
		this._owner = owner;
		this._isStatic = isStatic;
		this._signature = signature;
		this._name = name;
		this._locals = locals;
	}

	/** Walk `e`, the node's whole body — a function for a method, the value for a variable — and write the node's line. */
	public function root(e: TypedExpr): Void {
		_home = TypedFactsMacro.fileOf(e.pos);
		final at: String = _host.pos(e.pos, _home);
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
		for (category in CATEGORIES) {
			final list: Null<Array<String>> = _facts[category];
			if (list != null) out.add(',"$category":' + TypedFactsMacro.arr(list));
		}
		out.add('}');
		_host.nodes++;
		_host.line(out.toString());
	}

	private inline function at(p: Position): String {
		return _host.pos(p, _home);
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

	/** `p` without its brackets, for a fact written as a flat array. */
	private function range(p: Position): String {
		final full: String = at(p);
		return full.substring(1, full.length - 1);
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

	/** A value of `from` reaching a place of `to`, kept only when the two differ beyond nullability. */
	private function flow(from: Null<Type>, to: Null<Type>, how: String, p: Position): Void {
		final s: String = str(from);
		final d: String = str(to);
		if (d == '?' || unwrapNull(s) == unwrapNull(d)) return;
		add('flows', '{"s":${q(s)},"d":${q(d)},"c":"$how","p":${at(p)}}');
	}

	private function child(f: TypedExpr, localName: Null<String>): String {
		final min: Int = Context.getPosInfos(f.pos).min;
		final nested: TypedFactsWalk = new TypedFactsWalk(
			_host, '$id@$min', localName == null ? 'fn' : 'local', _owner, _isStatic, str(f.t), localName, _locals
		);
		add('fns', q(nested.id));
		nested.root(f);
		return nested.id;
	}

	private function walk(e: TypedExpr): Void {
		switch e.expr {
			case TFunction(_):
				child(e, null);
			case TLocal(v):
				if (!v.name.startsWith('`')) add('reads', '[${range(e.pos)},${q(localType(v))}]');
			case TVar(v, init):
				declare(v, e.pos);
				if (init != null) switch init.expr {
					case TFunction(_):
						_locals[v.id] = child(init, v.name);
					case _:
						flow(init.t, v.t, 'var', e.pos);
						walk(init);
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
				walk(receiver);
			case TBinop(OpAssign, lhs, rhs):
				flow(rhs.t, lhs.t, 'assign', e.pos);
				target(lhs, false);
				walk(rhs);
			case TBinop(OpAssignOp(op), lhs, rhs):
				if (op == OpAdd && isString(lhs.t) && !isString(rhs.t)) stringSite(rhs);
				target(lhs, true);
				walk(rhs);
			case TUnop(OpIncrement | OpDecrement, _, operand):
				target(operand, true);
			case TBinop(OpAdd, a, b) if (isString(e.t)):
				for (operand in [a, b]) if (!isString(operand.t)) stringSite(operand);
				walk(a);
				walk(b);
			case TReturn(value):
				if (value != null) {
					flow(value.t, _ret, 'ret', e.pos);
					walk(value);
				}
			case TArrayDecl(items):
				switch TypeTools.follow(e.t) {
					case TInst(_, [element]):
						for (item in items) flow(item.t, element, 'arr', item.pos);
					case _:
				}
				for (item in items) walk(item);
			case TObjectDecl(entries):
				switch TypeTools.follow(e.t) {
					case TAnonymous(a):
						final declared: Array<ClassField> = a.get().fields;
						for (entry in entries) {
							final slot: Null<ClassField> = Lambda.find(declared, f -> f.name == entry.name);
							if (slot != null) flow(entry.expr.t, slot.type, 'obj', entry.expr.pos);
						}
					case _:
				}
				for (entry in entries) walk(entry.expr);
			case TCast(inner, null):
				flow(inner.t, e.t, 'cast', e.pos);
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

	private function stringSite(operand: TypedExpr): Void {
		add('strs', '{"o":${q(str(operand.t))},"p":${at(operand.pos)}}');
	}

	/** The written side of an assignment: a field is a write (and a read too when `alsoRead`), anything else is walked. */
	private function target(lhs: TypedExpr, alsoRead: Bool): Void {
		switch lhs.expr {
			case TField(receiver, fa):
				fieldFact(lhs, receiver, fa, true);
				if (alsoRead) fieldFact(lhs, receiver, fa, false);
				walk(receiver);
			case _:
				walk(lhs);
		}
	}

	private function fieldFact(e: TypedExpr, receiver: TypedExpr, fa: FieldAccess, write: Bool): Void {
		final access: FieldRef = describe(fa);
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
				final access: FieldRef = describe(fa);
				final declaring: Null<String> = access.owner;
				final targetName: String = declaring == null ? access.field : '$declaring.${access.field}';
				if (access.kind == 'FStatic' && (declaring == 'Reflect' || declaring == 'Type')) reflection(targetName, args, where);
				if (access.kind == 'FStatic' && declaring != null && SYNTAX_CLASSES.contains(declaring))
					add('native', '{"w":"syntax","n":${q(targetName)},"p":$where}');
				walk(receiver);
				'{"t":${q(targetName)},"a":"${access.kind}","r":${q(str(receiver.t))},"rp":${at(receiver.pos)},$head}';
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

	private function reflection(targetName: String, args: Array<TypedExpr>, where: String): Void {
		var literal: String = '';
		var named: String = '';
		for (a in args) switch a.expr {
			case TConst(TString(s)) if (literal == ''):
				literal = ',"n":' + Json.stringify(s);
			case TTypeExpr(m) if (named == ''):
				named = ',"c":' + q(moduleTypeId(m));
			case _:
		}
		add('refl', '{"t":${q(targetName)}$literal$named,"p":$where}');
	}

	private function argFlows(fnType: Null<Type>, args: Array<TypedExpr>): Void {
		if (fnType == null) return;
		switch TypeTools.follow(fnType) {
			case TFun(params, _):
				for (i in 0...args.length) if (i < params.length && !isRest(params[i].t))
					flow(args[i].t, params[i].t, 'arg', args[i].pos);
			case _:
		}
	}

	private static inline function str(t: Null<Type>): String {
		return TypedFactsMacro.typeString(t, 0);
	}

	private static inline function q(s: String): String {
		return TypedFactsMacro.q(s);
	}

	private static function unwrapNull(t: String): String {
		return t.startsWith('Null<') && t.endsWith('>') ? t.substring(5, t.length - 1) : t;
	}

	private static function describe(fa: FieldAccess): FieldRef {
		return switch fa {
			case FInstance(c, _, cf): { owner: c.toString(), field: cf.toString(), kind: 'FInstance' };
			case FStatic(c, cf): { owner: c.toString(), field: cf.toString(), kind: 'FStatic' };
			case FAnon(cf): { owner: null, field: cf.toString(), kind: 'FAnon' };
			case FDynamic(dynamicName): { owner: null, field: dynamicName, kind: 'FDynamic' };
			case FClosure(c, cf): { owner: c == null ? null : c.c.toString(), field: cf.toString(), kind: 'FClosure' };
			case FEnum(en, ef): { owner: en.toString(), field: ef.name, kind: 'FEnum' };
		};
	}

	private static function moduleTypeId(m: ModuleType): String {
		return switch m {
			case TClassDecl(c): c.toString();
			case TEnumDecl(e): e.toString();
			case TTypeDecl(t): t.toString();
			case TAbstract(a): a.toString();
		};
	}

	private static function isRest(t: Type): Bool {
		return switch t {
			case TAbstract(a, _): a.toString() == 'haxe.extern.Rest';
			case _: false;
		};
	}

	private static function isString(t: Null<Type>): Bool {
		return t != null && switch TypeTools.follow(t) {
			case TInst(c, _): c.toString() == 'String';
			case _: false;
		};
	}

}

/** A field access as the facts name it: the owning type (none for a structure or a dynamic access), the field, the access kind. */
private typedef FieldRef = {
	final owner: Null<String>;
	final field: String;
	final kind: String;
};
#end

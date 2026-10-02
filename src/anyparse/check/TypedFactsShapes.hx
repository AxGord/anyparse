package anyparse.check;

#if macro
import haxe.Json;
import haxe.macro.Type;
import haxe.macro.TypeTools;
import haxe.macro.TypedExprTools;


/** The shapes of the typed tree `TypedFactsWalk` asks about, answered without walking. */
@:nullSafety(Strict)
final class TypedFactsShapes {

	/** The classes whose `code` calls are native code. */
	public static final SYNTAX_CLASSES: Array<String> = [
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

	/** The `*.Syntax` members that paste their first argument into the output as target code. */
	public static final SYNTAX_CODE_MEMBERS: Array<String> = ['code', 'plainCode'];

	/** The target intrinsics whose first argument is target code pasted into the output. */
	public static final CODE_INTRINSICS: Array<String> = [
		'__cpp__',
		'__js__',
		'__php__',
		'__python__',
		'__lua__',
		'__java__',
		'__cs__',
		'__hl__'
	];

	/** The metadata whose argument is target code pasted into the output: a field's, around its body, or a type's. */
	public static final CODE_METAS: Array<String> = [
		':functionCode',
		':functionTailCode',
		':cppFileCode',
		':cppNamespaceCode',
		':headerCode',
		':headerClassCode',
		':headerNamespaceCode',
		':classCode'
	];

	/** The classes whose members are reflection, called or read as a value. */
	public static final REFLECTION_CLASSES: Array<String> = ['Reflect', 'Type'];

	/**
	 * The target code a native call with the arguments `args` pastes into the output, as the tail of its `native` fact:
	 * `c`, the text of its first argument when that is a string literal; `cc` when the call carries code (`carrying`) whose
	 * text is computed; nothing for a call that carries none — a target function handed its arguments.
	 */
	public static function nativeCode(args: Array<TypedExpr>, carrying: Bool): String {
		final text: Null<String> = args.length == 0 ? null : literalText(args[0]);
		if (text != null) return ',"c":' + Json.stringify(text);
		return carrying ? ',"cc":true' : '';
	}

	/** The text of `e` when it is a string literal, through parentheses, metadata and an unchecked cast; null otherwise. */
	public static function literalText(e: TypedExpr): Null<String> {
		return switch e.expr {
			case TConst(TString(s)): s;
			case TParenthesis(inner) | TMeta(_, inner) | TCast(inner, null): literalText(inner);
			case _: null;
		};
	}

	/** The package of the class every exception the language throws as it is extends (`isException`). */
	private static inline final EXCEPTION_PACKAGE: String = 'haxe';

	/** The name of that class. */
	private static inline final EXCEPTION_NAME: String = 'Exception';

	/**
	 * The native identifier the chain of field accesses `e` is rooted at, through parentheses and metadata: target code the
	 * chain spells (`untyped __global__.String`). Null for any other expression, a bare identifier included.
	 */
	public static function nativeRoot(e: TypedExpr): Null<TypedExpr> {
		return switch e.expr {
			case TField(receiver, _): identRoot(receiver);
			case TParenthesis(inner) | TMeta(_, inner): nativeRoot(inner);
			case _: null;
		};
	}

	/** The text of the field chain `e` rooted at a native identifier (`nativeRoot`): its names joined by dots. */
	public static function chainText(e: TypedExpr): String {
		return switch e.expr {
			case TIdent(name): name;
			case TField(receiver, fa): chainText(receiver) + '.' + describe(fa).field;
			case TParenthesis(inner) | TMeta(_, inner): chainText(inner);
			case _: '';
		};
	}

	/** The native identifier `e` is, or the chain of field accesses `e` is rooted at; null otherwise. */
	private static function identRoot(e: TypedExpr): Null<TypedExpr> {
		return switch e.expr {
			case TIdent(_): e;
			case TField(receiver, _): identRoot(receiver);
			case TParenthesis(inner) | TMeta(_, inner): identRoot(inner);
			case _: null;
		};
	}

	public static function collectLeaves(e: TypedExpr, out: Array<TypedExpr>): Void {
		switch e.expr {
			case TIf(_, then, otherwise):
				collectLeaves(then, out);
				if (otherwise != null) collectLeaves(otherwise, out);
			case TSwitch(_, cases, otherwise):
				for (c in cases) collectLeaves(c.expr, out);
				if (otherwise != null) collectLeaves(otherwise, out);
			case TTry(body, catches):
				collectLeaves(body, out);
				for (c in catches) collectLeaves(c.expr, out);
			case TBlock(exprs) if (exprs.length > 0):
				collectLeaves(exprs[exprs.length - 1], out);
			case TParenthesis(inner) | TMeta(_, inner):
				collectLeaves(inner, out);
			case _:
				out.push(e);
		}
	}

	/**
	 * Whether every value `e` produces is built right there — an array literal, a `new Array`, `null` — so nothing but the
	 * place it is stored into holds it.
	 */
	public static function isFresh(e: TypedExpr): Bool {
		final leaves: Array<TypedExpr> = [];
		collectLeaves(e, leaves);
		return Lambda.foreach(
			leaves, leaf -> switch leaf.expr {
				case TArrayDecl(_) | TConst(TNull): true;
				case TNew(c, _, _): c.toString() == 'Array';
				case _: false;
			}
		);
	}

	public static function restElement(t: Type): Null<Type> {
		return switch TypeTools.follow(t) {
			case TAbstract(a, [element]) if (a.toString() == 'haxe.Rest' || a.toString() == 'haxe.extern.Rest'): element;
			case _: null;
		};
	}

	public static function describe(fa: FieldAccess): FieldRef {
		return switch fa {
			case FInstance(c, _, cf): { owner: c.toString(), field: cf.toString(), kind: 'FInstance' };
			case FStatic(c, cf): { owner: c.toString(), field: cf.toString(), kind: 'FStatic' };
			case FAnon(cf): { owner: null, field: cf.toString(), kind: 'FAnon' };
			case FDynamic(dynamicName): { owner: null, field: dynamicName, kind: 'FDynamic' };
			case FClosure(c, cf): { owner: c == null ? null : c.c.toString(), field: cf.toString(), kind: 'FClosure' };
			case FEnum(en, ef): { owner: en.toString(), field: ef.name, kind: 'FEnum' };
		};
	}

	public static function moduleTypeId(m: ModuleType): String {
		return switch m {
			case TClassDecl(c): c.toString();
			case TEnumDecl(e): e.toString();
			case TTypeDecl(t): t.toString();
			case TAbstract(a): a.toString();
		};
	}

	public static function isString(t: Null<Type>): Bool {
		return t != null && switch TypeTools.follow(t) {
			case TInst(c, _): c.toString() == 'String';
			case _: false;
		};
	}

	/**
	 * Whether `t` is a class extending `haxe.Exception`, or that class itself: the exception wrapping throws an instance of
	 * one as it is (`haxe.Exception.thrown`), and converts nothing.
	 */
	public static function isException(t: Type): Bool {
		var c: Null<ClassType> = switch TypeTools.follow(t) {
			case TInst(ref, _): ref.get();
			case _: null;
		};
		while (c != null) {
			final current: ClassType = c;
			if (current.pack.join('.') == EXCEPTION_PACKAGE && current.name == EXCEPTION_NAME) return true;
			c = current.superClass?.t.get();
		}
		return false;
	}

	/** The locals `body` ever assigns after their declaration: a function held by one of them is no fixed call target. */
	public static function writtenLocals(body: TypedExpr): Map<Int, Bool> {
		final out: Map<Int, Bool> = [];
		function scan(e: TypedExpr): Void {
			switch e.expr {
				case TBinop(OpAssign | OpAssignOp(_), { expr: TLocal(v) }, _) | TUnop(OpIncrement | OpDecrement, _, { expr: TLocal(v) }):
					out[v.id] = true;
				case _:
			}
			TypedExprTools.iter(e, scan);
		}
		scan(body);
		return out;
	}

}

/** A field access as the facts name it: the owning type (none for a structure or a dynamic access), the field, the access kind. */
typedef FieldRef = {
	final owner: Null<String>;
	final field: String;
	final kind: String;
};
#end

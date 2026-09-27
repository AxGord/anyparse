package anyparse.check;

#if macro
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

	/** The classes whose members are reflection, called or read as a value. */
	public static final REFLECTION_CLASSES: Array<String> = ['Reflect', 'Type'];

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

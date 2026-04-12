package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Type;

/**
 * Compile-time constants extracted from a resolved format class.
 * Phase 2 only needs the whitespace-skip string; Phase 3+ will grow
 * this record as more strategies consult format fields at macro time.
 */
typedef FormatInfo = {
	/** Characters to consume when `@:ws` is active on the schema. */
	whitespace:String,

	/** Fully qualified type path of the `@:schema` class (e.g. `anyparse.format.text.JsonFormat`). */
	schemaTypePath:String,
};

/**
 * Resolves a `@:schema(ClassName)` reference at macro time and extracts
 * compile-time constants from its field initializers.
 *
 * The mechanism is deliberately simple: we call `Context.getType` to
 * force the format class to be typed, then walk its `fields` array and
 * pattern-match the typed initializer of each field we care about.
 * Fields declared as `(default, null)` properties with a literal
 * initializer at the declaration site come through here as
 * `TConst(TString(...))` / `TConst(TInt(...))` etc. — enough for the
 * JSON case. Richer extraction (expressions, references) is left for
 * later phases when real formats need it.
 */
class FormatReader {

	public static function resolve(typePath:String):FormatInfo {
		final t:Type = Context.getType(typePath);
		final cl:ClassType = switch t {
			case TInst(ref, _): ref.get();
			case _:
				Context.fatalError('@:schema($typePath) must resolve to a class', Context.currentPos());
				throw 'unreachable';
		};
		return {
			whitespace: readStringField(cl, 'whitespace'),
			schemaTypePath: typePath,
		};
	}

	private static function readStringField(cl:ClassType, fieldName:String):String {
		final fields:Array<ClassField> = cl.fields.get();
		for (f in fields) if (f.name == fieldName) {
			final texpr:Null<TypedExpr> = f.expr();
			if (texpr != null) {
				final s:Null<String> = extractString(texpr);
				if (s != null) return s;
			}
		}
		Context.fatalError('format class ${cl.name} has no readable String field "$fieldName"', Context.currentPos());
		throw 'unreachable';
	}

	private static function extractString(texpr:TypedExpr):Null<String> {
		return switch texpr.expr {
			case TConst(TString(s)): s;
			case TCast(inner, _): extractString(inner);
			case TParenthesis(inner): extractString(inner);
			case _: null;
		};
	}
}
#end

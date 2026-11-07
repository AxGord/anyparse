package anyparse.macro;

using StringTools;

import haxe.macro.Expr;
import haxe.macro.ExprTools;
#if macro
import haxe.macro.Context;
#end

/**
 * The one answer to "how does a generated string literal keep its bytes through the hxcpp C++ compiler".
 *
 * gencpp copies a Haxe string literal verbatim into a C++ string literal, and a C++ compiler in a pre-C++17 mode
 * replaces a trigraph (`??=` becomes `#`) before it lexes, so a grammar literal `??=` would match `#` on hxcpp and one
 * grammar would parse differently per target. On a cpp build every generated literal holding a trigraph is re-emitted
 * as a C++ literal whose `?` are escaped. Only `guard` is macro-only: the rewrite itself runs on any target, so the
 * suite reads what it does to a fixture class.
 */
@:nullSafety(Strict)
final class CppLiteralGuard {

	/** The characters that make a trigraph when they follow `??`. */
	private static inline final TRIGRAPH_TAILS: String = "=/'()!<>-";

	/** The first code past printable ASCII: DEL. */
	private static inline final DEL: Int = 0x7F;

	/**
	 * The C++ string literal, quotes included, spelling `s` with every `?`, `\` and `"` escaped; null when `s` holds no
	 * trigraph, or holds a character outside printable ASCII (hxcpp stores non-ASCII text as UTF-16, which a narrow
	 * literal cannot spell).
	 */
	public static function cppLiteral(s: String): Null<String> {
		if (!hasTrigraph(s)) return null;
		final out: StringBuf = new StringBuf();
		out.addChar('"'.code);
		for (i in 0...s.length) {
			final c: Int = s.fastCodeAt(i);
			if (c < ' '.code || c >= DEL) return null;
			if (c == '?'.code || c == '\\'.code || c == '"'.code) out.addChar('\\'.code);
			out.addChar(c);
		}
		out.addChar('"'.code);
		return out.toString();
	}

	/** Whether `s` holds a `??` followed by a trigraph tail. */
	public static function hasTrigraph(s: String): Bool {
		for (i in 0...s.length - 2) if (s.charAt(i) == '?' && s.charAt(i + 1) == '?' && TRIGRAPH_TAILS.indexOf(s.charAt(i + 2)) >= 0)
			return true;
		return false;
	}

	/**
	 * Re-emits in place, whatever the target, every trigraph-bearing literal of a function body or a non-inline
	 * initialiser of `fields` as a static hxcpp string; answers the trigraph-bearing literals it must leave as written:
	 * a switch case value, an inline constant, an interpolated single-quoted string, one `cppLiteral` cannot spell.
	 */
	public static function rewriteFields(fields: Array<Field>): Array<Expr> {
		final stranded: Array<Expr> = [];
		for (field in fields) switch field.kind {
			case FFun(fn):
				final body: Null<Expr> = fn.expr;
				if (body != null) fn.expr = rewrite(body, stranded);
			case FVar(type, init):
				final inlined: Bool = field.access != null && field.access.contains(AInline);
				if (init != null && inlined) strand(init, stranded);
				if (init != null && !inlined) field.kind = FVar(type, rewrite(init, stranded));
			case FProp(_, _, _, _):
		}
		return stranded;
	}

	#if macro
	/**
	 * `rewriteFields(fields)` on a cpp build, failing the build at each trigraph-bearing literal it had to leave as
	 * written, since the C++ compiler would rewrite that literal; on any other target `fields` untouched.
	 */
	public static function guard(fields: Array<Field>): Array<Field> {
		if (!Context.defined('cpp')) return fields;
		for (literal in rewriteFields(fields))
			Context.error(
				'this literal holds a C++ trigraph where a constant is required, so hxcpp would compile other bytes', literal.pos
			);
		return fields;
	}
	#end

	private static function rewrite(e: Expr, stranded: Array<Expr>): Expr {
		return switch e.expr {
			case EConst(CString(s, kind)):
				final literal: Null<String> = kind == SingleQuotes && s.indexOf('$') >= 0 ? null : cppLiteral(s);
				if (literal == null && hasTrigraph(s)) stranded.push(e);
				literal == null ? e : nativeString(literal, e.pos);
			case ESwitch(subject, cases, fallback):
				for (c in cases) for (value in c.values) strand(value, stranded);
				final rewritten: Array<Case> = [
					for (c in cases) {
						values: c.values,
						guard: c.guard == null ? null : rewrite(c.guard, stranded),
						expr: c.expr == null ? null : rewrite(c.expr, stranded)
					}
				];
				{ expr: ESwitch(rewrite(subject, stranded), rewritten, fallback == null ? null : rewrite(fallback, stranded)), pos: e.pos };
			case ECall({ expr: EConst(CIdent('__cpp__')) }, _): e;
			case _: ExprTools.map(e, x -> rewrite(x, stranded));
		}
	}

	/** `(untyped __cpp__('HX_CSTRING(<literal>)') : String)`: a static hxcpp string spelled by the C++ literal `literal`. */
	private static function nativeString(literal: String, pos: Position): Expr {
		final code: Expr = { expr: EConst(CString('HX_CSTRING($literal)', DoubleQuotes)), pos: pos };
		final call: Expr = { expr: ECall({ expr: EConst(CIdent('__cpp__')), pos: pos }, [code]), pos: pos };
		return { expr: ECheckType({ expr: EUntyped(call), pos: pos }, TPath({ pack: [], name: 'String', params: [] })), pos: pos };
	}

	/** Collects into `stranded` every trigraph-bearing literal of `e`, which stays as written. */
	private static function strand(e: Expr, stranded: Array<Expr>): Void {
		switch e.expr {
			case EConst(CString(s, _)) if (hasTrigraph(s)):
				stranded.push(e);
			case _:
				ExprTools.iter(e, x -> strand(x, stranded));
		}
	}

}

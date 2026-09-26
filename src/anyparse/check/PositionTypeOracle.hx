package anyparse.check;

import anyparse.check.Check.OracleType;
import anyparse.check.Check.TypeOracle;
import anyparse.runtime.Span;

/**
 * A `TypeOracle` answering every structural question with ONE byte-position query, `typeAt` — the
 * shape of the Haxe display protocol (`CompilerDisplayOracle`). A declaration is asked at the last
 * character of its name token, where the display server resolves it; a return type is the result
 * half of the function type printed there (`ExplicitType.returnTypeOf`); an expression is asked at
 * its last character. What the server names is returned verbatim: it is already Haxe source.
 */
@:nullSafety(Strict)
abstract class PositionTypeOracle implements TypeOracle {

	/** What a position-based oracle declines with when the position carries no type. */
	public static inline final DECLINE_NO_ANSWER: String = 'the display server named no type at the declaration';

	/** The compiler's inferred type at `bytePos` in `file` (XML-decoded, trimmed), or null when none / the query failed. */
	public abstract function typeAt(file: String, bytePos: Int): Null<String>;

	public function localType(file: String, decl: Span, name: String, nameEnd: Int): OracleType {
		return answer(typeAt(file, nameEnd - 1));
	}

	public function returnType(file: String, fn: Span, name: String, nameEnd: Int): OracleType {
		final raw: Null<String> = typeAt(file, nameEnd - 1);
		final ret: Null<String> = raw == null ? null : ExplicitType.returnTypeOf(raw);
		return ret == null ? Declined(DECLINE_NO_ANSWER) : Typed(ret);
	}

	public function paramType(file: String, fn: Span, name: String, index: Int, param: String, nameEnd: Int): OracleType {
		return answer(typeAt(file, nameEnd - 1));
	}

	public function fieldType(file: String, field: Span, name: String, nameEnd: Int): OracleType {
		return answer(typeAt(file, nameEnd - 1));
	}

	public function expressionType(file: String, expr: Span): OracleType {
		return answer(typeAt(file, expr.to - 1));
	}

	private static function answer(raw: Null<String>): OracleType {
		return raw == null ? Declined(DECLINE_NO_ANSWER) : Typed(raw);
	}

}

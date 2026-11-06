package unit.macro;

import anyparse.macro.CppLiteralGuard;

using StringTools;

/**
 * The C++ spelling `CppLiteralGuard` gives a generated literal on a cpp build: a trigraph has its `?` escaped so the
 * C++ compiler cannot rewrite it, and a literal it cannot spell or need not touch is left to gencpp. The hxcpp end of
 * the same claim is `dev jvm-portability --cpp` over `tools/data/portability`. Which literals of a class the rewrite
 * reaches is read off `CppLiteralGuardProbe`'s fixture, rewritten while the suite compiles.
 */
@:nullSafety(Strict)
final class CppLiteralGuardTest extends Test {

	/** `CppLiteralGuardProbe`'s fixture after `rewriteFields`, printed while the suite compiled. */
	private static final PROBE: { text: String, stranded: Array<String> } = CppLiteralGuardProbe.rewritten();

	/** The fixture's fields as text after the rewrite. */
	private static final REWRITTEN: String = PROBE.text;

	@:pin('control')
	@:killer('M-CPP-LITERAL-RAW-QUESTION')
	public function testATrigraphHasItsQuestionMarksEscaped(): Void {
		Assert.equals('"a \\?\\?= b"', CppLiteralGuard.cppLiteral('a ??= b'));
	}

	@:pin('control')
	@:killer('M-CPP-TRIGRAPH-NONE')
	public function testEveryTrigraphTailIsCaught(): Void {
		for (tail in ['=', '/', '\'', '(', ')', '!', '<', '>', '-']) Assert.notNull(CppLiteralGuard.cppLiteral('??$tail'), tail);
	}

	@:pin('control')
	@:killer('M-CPP-TRIGRAPH-ALWAYS')
	public function testAQuestionPairWithNoTailIsLeftAlone(): Void {
		for (literal in ['a ?? b', '??', '?=', '?.x', '']) Assert.isNull(CppLiteralGuard.cppLiteral(literal), literal);
	}

	@:pin('control')
	@:killer('M-CPP-LITERAL-RAW-QUOTE')
	public function testAQuoteAndABackslashAreEscaped(): Void {
		Assert.equals('"\\"\\?\\?=\\\\\\""', CppLiteralGuard.cppLiteral('"??=\\"'));
	}

	@:pin('control')
	@:killer('M-CPP-LITERAL-ANY-CHAR')
	public function testALiteralOutsidePrintableAsciiIsLeftAlone(): Void {
		Assert.isNull(CppLiteralGuard.cppLiteral('??=é'), 'non-ASCII');
		Assert.isNull(CppLiteralGuard.cppLiteral('??=\n'), 'a control byte');
	}

	@:pin('control')
	@:killer('M-CPP-GUARD-BODY-RAW')
	public function testABodyLiteralIsRewritten(): Void {
		Assert.isFalse(REWRITTEN.contains('??='));
		Assert.stringContains('HX_CSTRING', REWRITTEN);
	}

	@:pin('control')
	@:killer('M-CPP-GUARD-CASE-VALUES-REWRITTEN')
	public function testACaseValueStaysRaw(): Void {
		Assert.stringContains('??(', REWRITTEN);
	}

	@:pin('control')
	@:killer('M-CPP-GUARD-CASE-GUARD-RAW')
	public function testACaseGuardAndBodyAreRewritten(): Void {
		for (raw in ['??)', '??<', '??>']) Assert.isFalse(REWRITTEN.contains(raw), raw);
	}

	@:pin('control')
	@:killer('M-CPP-GUARD-INLINE-REWRITTEN')
	public function testAnInlineConstantStaysRaw(): Void {
		Assert.stringContains('??/', REWRITTEN);
	}

	@:pin('control')
	@:killer('M-CPP-GUARD-INIT-RAW')
	public function testANonInlineInitIsRewritten(): Void {
		// the printer spells a raw `'` inside a double-quoted literal as `\'`
		Assert.isFalse(REWRITTEN.contains("??'") || REWRITTEN.contains("??\\'"));
	}

	@:pin('control')
	@:killer('M-CPP-GUARD-INTERPOLATION-REWRITTEN')
	public function testAnInterpolatedLiteralStaysRaw(): Void {
		Assert.stringContains('??!', REWRITTEN);
	}

	@:pin('control')
	@:killer('M-CPP-GUARD-CPP-REENTERED')
	public function testANativeCallIsNotReentered(): Void {
		Assert.stringContains('??-', REWRITTEN);
	}

	@:pin('control')
	@:killer('M-CPP-TRIGRAPH-ALWAYS')
	public function testALiteralWithNoTrigraphIsUntouched(): Void {
		Assert.stringContains('a ?? b', REWRITTEN);
	}

	@:pin('control')
	@:killer('M-CPP-GUARD-STRAND-NONE')
	public function testTheLiteralsLeftRawAreAnswered(): Void {
		Assert.equals("??/|??(|??! $n", PROBE.stranded.join('|'));
	}

}

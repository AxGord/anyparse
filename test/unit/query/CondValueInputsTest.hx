package unit.query;

import anyparse.query.CondRegionLiveness;
import anyparse.query.GrammarPlugin.RefShape;

/**
 * Every input shape the `#if` condition reader accepts or refuses, one row each: the condition text and what
 * `evaluateFacts` answers (true, false, or null for a condition it does not decide). The table was recorded from the
 * hand-written reader before the generated one replaced it, so a row is the reader's contract, not a re-derivation.
 */
@:nullSafety(Strict)
final class CondValueInputsTest extends Test {

	/** The Haxe grammar, whose condition reader every row goes through. */
	private static final SHAPE: RefShape = new HaxeQueryPlugin().refShape();

	/** `a`, `b`, the dotted `a.b` and a flag named `version` are set; `u` is asserted absent; every other name is unknown. */
	private static final FLAGS: DefineFacts = { defined: ['a', 'b', 'a.b', 'version'], undefined: ['u'] };

	/** `a` is the string `1` and `b` the string `2`, so comparisons are decided. */
	private static final VALUED: DefineFacts = { defined: ['a', 'b'], undefined: ['u'], values: ['a' => '1', 'b' => '2'] };

	@:pin('control')
	@:killer('M-COND-VALUE-NOT')
	@:killer('M-CONDVALUE-NOT-GONE')
	public function testNegationsStackAndTakeBlanks(): Void {
		holds([
			row('a', true),
			row('!a', false),
			row('!!a', true),
			row('!!!a', false),
			row('! a', false),
			row('!\ta', false),
			row('u', false),
			row('!u', true),
			row('(!a)', false),
			row('!(a)', false),
			row('!', null),
			row('!!', null)
		], FLAGS);
	}

	@:pin('control')
	@:killer('M-COND-VALUE-GROUP')
	@:killer('M-CONDVALUE-GROUP-BRACKET')
	public function testGroupsNestAndMustClose(): Void {
		holds([
			row('(a)', true),
			row('((a))', true),
			row('( a )', true),
			row('()', null),
			row('(a', null),
			row('a)', null),
			row('', null),
			row('   ', null),
			row('(a && b)', true),
			row('(a) && (b)', true)
		], FLAGS);
	}

	@:pin('control')
	@:killer('M-COND-VALUE-AND')
	@:killer('M-COND-VALUE-OR')
	public function testBooleanOperatorsAreThreeValued(): Void {
		holds([
			row('a && b', true),
			row('a&&b', true),
			row('a\t&&\tb', true),
			row('a || x', true),
			row('x || a', true),
			row('x && a', null),
			row('u && x', false),
			row('x || x', null),
			row('a && ', null),
			row('&& a', null),
			row('|| a', null),
			row('a &&', null),
			row('a & b', null),
			row('a | b', null),
			row('u || u', false),
			row('a || b && x', true),
			row('x && b || a', true)
		], FLAGS);
	}

	@:pin('control')
	@:killer('M-COND-VALUE-VERSION')
	@:killer('M-CONDVALUE-VERSION-FLAG')
	public function testVersionCallTakesOneStringAndKeepsItsBlanks(): Void {
		holds([
			row('version("1.2.3")', true),
			row('version( "1.2.3" )', true),
			row('version ("1.2.3")', true),
			row('version(\'1.2.3\')', true),
			row('version("1.2")', null),
			row('version(x)', null),
			row('version("1.2.3"', null),
			row('version("1.2.3", "1")', null),
			row('version("1\\.2.3")', null),
			row('version', true),
			row('version()', null),
			row('version("1.2.3") ==', null),
			row('version("1.2.3") && a', true),
			row('version("1.2.3") > version("1.2.2")', true),
			row('version("1.2.3") < version("1.2.2")', false)
		], FLAGS);
	}

	@:pin('control')
	@:killer('M-COND-FLAG-DOTTED')
	public function testDottedFlagsEndAtADotWithNoNameAfterIt(): Void {
		holds([
			row('a.b', true),
			row('a.b.', null),
			row('a.', null),
			row('.a', null),
			row('a..b', null),
			row('a.b.c', null),
			row('a.b && b', true)
		], FLAGS);
	}

	@:pin('control')
	@:killer('M-COND-VALUE-NUMBER')
	@:killer('M-COND-NUMBER-DOTTED')
	public function testNumbersAreDigitAndDotRuns(): Void {
		holds([
			row('1', true),
			row('0', false),
			row('1.5', true),
			row('0.0', false),
			row('1.2.3', null),
			row('1.', null),
			row('1a', null),
			row('1 == 1', true),
			row('1.5 >= 1.2', true),
			row('1 < 1', false),
			row('2 != 2', false)
		], FLAGS);
	}

	@:pin('control')
	@:killer('M-COND-QUOTED-UNTERMINATED')
	public function testQuotedStringsAreTextAndRefuseEscapesAndUnclosedQuotes(): Void {
		holds([
			row('"x"', true),
			row('\'x\'', true),
			row('""', true),
			row('"a\\"b"', null),
			row('"x', null),
			row('\'x', null),
			row('"x" == "x"', true),
			row('"x" != "y"', true),
			row('"x" == "y"', false),
			row('"x" "y"', null)
		], FLAGS);
	}

	@:pin('control')
	@:killer('M-COND-VALUE-CHAIN')
	@:killer('M-CONDVALUE-CMP-LOOSE')
	@:killer('M-CONDVALUE-GTEQ-SHADOWED')
	public function testOneComparisonOfTwoUnaryOperandsAndNothingElse(): Void {
		holds([
			row('a == 1', true),
			row('a == 2', false),
			row('a < b', true),
			row('a<b', true),
			row('a> b', false),
			row('a >= b', false),
			row('a <= b', true),
			row('a != b', true),
			row('a ==', null),
			row('== a', null),
			row('a === b', null),
			row('a = b', null),
			row('a <> b', null),
			row('a == b == a', null),
			row('(a == b) == a', false),
			row('a == b == a || a', null),
			row('(a == b == a)', null),
			row('a == b || a', true),
			row('a == !b', false),
			row('!a == b', false),
			row('!a == !b', true),
			row('a == (b)', false),
			row('(a) == a', true),
			row('a == b && a == b', false),
			row('a == b || a == a', true)
		], VALUED);
	}

	@:pin('guard')
	public function testTrailingTextIsRefused(): Void {
		holds([
			row('a b', null),
			row('a;', null),
			row('#a', null),
			row('@', null),
			row('a)', null),
			row('a ,', null)
		], FLAGS);
	}

	/** A condition spread over lines is the compiler's own: line breaks and comments are blanks like spaces. */
	@:pin('control')
	@:killer('M-COND-VALUE-SCHEMA-LINE-COMMENT')
	public function testLineBreaksAndCommentsAreBlanks(): Void {
		holds([
			row('a\n&& b', true),
			row('(a\r\n&&\n\tb)', true),
			row('!\na', false),
			row('a /* c */ && b', true),
			row('a // c\n&& b', null),
			row('(a // c\n)', null),
			row('version(\n"1.2.3"\n)', true),
			row('(a ==\nb)', null)
		], FLAGS);
		holds([row('a ==\nb', false), row('a\n<\nb', true)], VALUED);
	}

	private static function row(condition: String, expected: Null<Bool>): { final condition: String; final expected: Null<Bool>; } {
		return { condition: condition, expected: expected };
	}

	private static function holds(rows: Array<{ final condition: String; final expected: Null<Bool>; }>, facts: DefineFacts): Void {
		for (r in rows) Assert.equals(r.expected, CondRegionLiveness.evaluateFacts(r.condition, SHAPE, facts), 'condition: ${r.condition}');
	}

}

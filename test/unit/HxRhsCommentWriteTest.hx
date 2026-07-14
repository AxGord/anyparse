package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;

/**
 * Trivia-mode round-trip tests for a BLOCK comment trailing the right operand
 * of a non-chain binop (position #3 — before the enclosing `)`/`;`/`,`).
 * Covers comparisons, arithmetic, and `is`; confirms a same-line LINE comment
 * is NOT stolen from an enclosing chain operator (it routes to the chain's
 * line-break), and a comment-free binop is unaffected.
 */
class HxRhsCommentWriteTest extends Test {

	private static final forceBuild: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	public function testComparisonTrailingBlockComment(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tvar a = x == y /* eq */;\n\t}\n}';
		Assert.equals(source + '\n', roundTrip(source));
	}

	public function testComparisonInConditionBlockComment(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tif (t == u /* cond */) {\n\t\t\trun();\n\t\t}\n\t}\n}';
		Assert.equals(source + '\n', roundTrip(source));
	}

	public function testArithmeticTrailingBlockComment(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tvar b = i * j /* mul */;\n\t}\n}';
		Assert.equals(source + '\n', roundTrip(source));
	}

	public function testIsTrailingBlockComment(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tvar c = x is Int /* isc */;\n\t}\n}';
		Assert.equals(source + '\n', roundTrip(source));
	}

	public function testLineCommentRoutedToChainNotStolen(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tvar b = a == n // note\n\t\t\t&& c == m;\n\t}\n}';
		Assert.equals(source + '\n', roundTrip(source));
	}

	public function testComparisonNoCommentUnaffected(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tvar a = x == y;\n\t}\n}';
		Assert.equals(source + '\n', roundTrip(source));
	}

	private function roundTrip(source: String): String {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		return HaxeModuleTriviaWriter.write(ast);
	}

}

package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;

/**
 * Trivia-mode round-trip tests for a comment trailing the left operand of
 * an infix chain operator (`+` / `-` / `&&` / `||`). A block comment stays
 * inline (`a /* c *\/ + b`); a line comment forces the operator onto the
 * continuation line (`a // c` then `+ b`) since `//` runs to end of line.
 * These were previously dropped by the Pratt stash.
 */
class HxInfixCommentWriteTest extends Test {

	private static final _forceBuild: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	private function roundTrip(source: String): String {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		return HaxeModuleTriviaWriter.write(ast);
	}

	public function testInfixLeadingLineCommentForcesWrap(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tvar s = a // note\n\t\t\t+ b;\n\t}\n}';
		Assert.equals('class Foo {\n\tfunction bar() {\n\t\tvar s = a // note\n\t\t\t+ b;\n\t}\n}\n', roundTrip(source));
	}

	public function testInfixLeadingBlockCommentInline(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tvar s = a /* c */ + b;\n\t}\n}';
		Assert.equals('class Foo {\n\tfunction bar() {\n\t\tvar s = a /* c */ + b;\n\t}\n}\n', roundTrip(source));
	}

	public function testBoolChainLeadingBlockCommentInline(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tvar t = aa /* x */ && bb;\n\t}\n}';
		Assert.equals('class Foo {\n\tfunction bar() {\n\t\tvar t = aa /* x */ && bb;\n\t}\n}\n', roundTrip(source));
	}

	public function testInfixMidChainBlockCommentInline(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tvar s = a + b /* c */ + d;\n\t}\n}';
		Assert.equals('class Foo {\n\tfunction bar() {\n\t\tvar s = a + b /* c */ + d;\n\t}\n}\n', roundTrip(source));
	}

	public function testInfixPostOperatorLineCommentBoolChain(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tvar b = f1() || // one\n\t\t\tf2() || // two\n\t\t\tf3();\n\t}\n}';
		Assert.equals(source + '\n', roundTrip(source));
	}

	public function testInfixPostOperatorLineCommentAddChain(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tvar s = a + // plus\n\t\t\tb;\n\t}\n}';
		Assert.equals(source + '\n', roundTrip(source));
	}

}

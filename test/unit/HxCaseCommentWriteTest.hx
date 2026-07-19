package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;

/**
 * Trivia-mode round-trip tests for a comment trailing a switch `case` label
 * (after the `:`). The fork keeps it on the case-colon line; anyparse used
 * to relocate it below. Covers line and block styles, an empty-body case,
 * and confirms a case with no trailing comment is unaffected.
 */
class HxCaseCommentWriteTest extends Test {

	private static final forceBuild: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	public function testCaseLabelLineCommentStaysOnColonLine(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tswitch (x) {\n\t\t\tcase A: // note\n\t\t\t\trun();\n\t\t}\n\t}\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	public function testCaseLabelBlockCommentStaysOnColonLine(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tswitch (x) {\n\t\t\tcase A: /* blk */\n\t\t\t\trun();\n\t\t}\n\t}\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	public function testEmptyCaseLabelLineCommentStaysOnColonLine(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tswitch (x) {\n\t\t\tcase A: // note\n\t\t\tcase B:\n\t\t\t\trun();\n\t\t}\n\t}\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	public function testCaseLabelNoCommentUnaffected(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tswitch (x) {\n\t\t\tcase A: run();\n\t\t}\n\t}\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	private function roundTrip(source: String): String {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		return HaxeModuleTriviaWriter.write(ast);
	}

}

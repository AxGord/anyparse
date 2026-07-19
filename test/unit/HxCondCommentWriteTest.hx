package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;

/**
 * Trivia-mode round-trip tests for comments inside `#if`/`#elseif`/`#else`/`#end`
 * conditional-compilation branches: a LEADING comment first in an `#else` branch
 * (CLASS D) and a TRAILING comment as the last item of a branch before the close
 * marker (CLASS A). Verifies the close marker (`#end`) still lands on its own
 * line (the output re-parses).
 */
class HxCondCommentWriteTest extends Test {

	private static final forceBuild: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	public function testElseBranchLeadingComment(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\t#if a\n\t\treturn 0;\n\t\t#else\n\t\t// note\n\t\treturn 1;\n\t\t#end\n\t}\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	public function testElseBranchTrailingCommentBeforeEnd(): Void {
		final source: String = 'class Foo {\n\t#if a\n\tstatic var x = 1;\n\t#else\n\tstatic var y = 2;\n\t// note\n\t#end\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	public function testIfBranchTrailingCommentBeforeEnd(): Void {
		final source: String = 'class Foo {\n\t#if a\n\tstatic var y = 2;\n\t// note\n\t#end\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	public function testCondBranchNoCommentUnaffected(): Void {
		final source: String = 'class Foo {\n\t#if a\n\tstatic var x = 1;\n\t#else\n\tstatic var y = 2;\n\t#end\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	private function roundTrip(source: String): String {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		return HaxeModuleTriviaWriter.write(ast);
	}

}

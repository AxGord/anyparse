package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;

/**
 * Regression guard for the `#if`/`#elseif`/`#else`/`#end` multi-clause chain
 * double-newline bug: the `elseifs` Star's inter-clause separator used to emit
 * its own hardline ON TOP OF the preceding clause body's `@:fmt(padTrailing)`
 * hardline, inserting a spurious blank line before every `#elseif` after the
 * first — a blank that COMPOUNDED on each re-format (non-idempotent). The fix
 * (`@:fmt(elemSelfTrailsNewline)` on the cond-comp `elseifs` fields) suppresses
 * the redundant base hardline while still emitting authored blank-line extras.
 */
class HxCondElseifChainBlankTest extends Test {

	private static final forceBuild: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	public function testStmtChainNoSpuriousBlank(): Void {
		final source: String = 'class M {\n\tfunction f() {\n\t\t#if a\n\t\treturn 1;\n\t\t#elseif b\n\t\treturn 2;\n\t\t#elseif c\n\t\treturn 3;\n\t\t#elseif d\n\t\treturn 4;\n\t\t#end\n\t}\n}';
		Assert.equals(source + '\n', roundTrip(source));
	}

	public function testStmtChainIdempotent(): Void {
		final source: String = 'class M {\n\tfunction f() {\n\t\t#if a\n\t\treturn 1;\n\t\t#elseif b\n\t\treturn 2;\n\t\t#elseif c\n\t\treturn 3;\n\t\t#end\n\t}\n}';
		final once: String = roundTrip(source);
		Assert.equals(once, roundTrip(once));
	}

	public function testMemberChainNoSpuriousBlank(): Void {
		final source: String = 'class M {\n\t#if a\n\tvar x = 1;\n\t#elseif b\n\tvar y = 2;\n\t#elseif c\n\tvar z = 3;\n\t#end\n}';
		Assert.equals(source + '\n', roundTrip(source));
	}

	public function testAuthoredBlankBeforeElseifPreserved(): Void {
		final source: String = 'class M {\n\tfunction f() {\n\t\t#if a\n\t\treturn 1;\n\t\t#elseif b\n\t\treturn 2;\n\n\t\t#elseif c\n\t\treturn 3;\n\t\t#end\n\t}\n}';
		Assert.equals(source + '\n', roundTrip(source));
	}

	private function roundTrip(source: String): String {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		return HaxeModuleTriviaWriter.write(ast);
	}

}

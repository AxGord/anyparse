package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

/**
 * Regression guard for slice ω-if-modifier — `#if COND <modifiers> #end`
 * interleaved with regular modifiers inside a class-member modifier
 * list. Covers the positional variants observed in the haxe-formatter
 * fixtures `issue_107_inline_sharp`, `issue_291_conditional_modifier`,
 * and `issue_332_conditional_modifiers` (V1–V4).
 *
 * Single-line variants (V2, V3, `issue_107`, `issue_291`) and V1 assert
 * that the input parses AND that `parse → write` round-trips byte-
 * exactly. V2 / V3 use the writer-side gate closed by
 * `@:fmt(padLeading, padTrailing)` on `HxConditionalMod.body`
 * (cond↔body[0] and body[last]↔`#end` boundary spaces). V1 (`#if … #end`
 * followed by a newline-and-indent before the next modifier keyword)
 * uses the
 * `@:trivia` capture added on `HxMemberDecl.modifiers` (per-element
 * `newlineBefore` slot consumed by the trivia tryparse Star writer to
 * emit a hardline between modifiers when the source had a single
 * newline boundary).
 *
 * V4 (cond / modifier / `#end` on separate lines) round-trips via
 * `@:trivia` on `HxConditionalMod.body` plus a padLeading/padTrailing-
 * aware branch in `triviaTryparseStarExpr`. The first body element's
 * captured `newlineBefore` flag drives both pad slots — when set, both
 * cond↔body and body↔`#end` gaps render as hardlines; otherwise the
 * single-line shape (V1–V3: `<cond> mods #end`) is preserved with
 * fixed-space padding.
 *
 * The fork fixtures' output sections are trailing-newline-terminated,
 * so `roundTrip` appends `'\n'` to the input when computing the
 * expected output.
 */
class CondModProbe extends Test {

	private static final forceBuildParser: Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;
	private static final forceBuildWriter: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	public inline function testIssue107(): Void {
		roundTrip('class Main {\n\t#if !cppia inline #end function addChar(c:Int):Void {}\n}');
	}

	public inline function testIssue291(): Void {
		roundTrip(
			'class Xml {\n\tvar nodeName:String = "";\n\n\t#if !cppia inline #end function get_nodeName() {\n\t\treturn nodeName;\n\t}\n}'
		);
	}

	public inline function testIssue332V1(): Void {
		roundTrip('class Main {\n\t#if (neko_v21 || (cpp && !cppia) || flash) inline #end\n\tpublic static function main() {}\n}');
	}

	public inline function testIssue332V2(): Void {
		roundTrip('class Main {\n\t#if (neko_v21 || (cpp && !cppia) || flash) inline #end public static function main() {}\n}');
	}

	public inline function testIssue332V3(): Void {
		roundTrip('class Main {\n\tpublic static #if (neko_v21 || (cpp && !cppia) || flash) inline #end function main() {}\n}');
	}

	public inline function testIssue332V4(): Void {
		roundTrip('class Main {\n\t#if (neko_v21 || (cpp && !cppia) || flash)\n\tinline\n\t#end\n\tpublic static function main() {}\n}');
	}

	private static function roundTrip(source: String): Void {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out: String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals('$source\n', out);
	}

}

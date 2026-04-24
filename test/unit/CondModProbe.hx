package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;

/**
 * Regression guard for slice ω-if-modifier — `#if COND <modifiers> #end`
 * interleaved with regular modifiers inside a class-member modifier
 * list. Covers the positional variants observed in the haxe-formatter
 * fixtures `issue_107_inline_sharp`, `issue_291_conditional_modifier`,
 * and `issue_332_conditional_modifiers` (V1–V3).
 *
 * Single-line variants (V2, V3, `issue_107`, `issue_291`) assert that
 * the input parses AND that `parse → write` round-trips byte-exactly —
 * the writer-side gate closed by `@:fmt(padBoundaries)` on
 * `HxConditionalMod.body` (cond↔body[0] and body[last]↔`#end` boundary
 * spaces). The fork fixtures' output sections are
 * trailing-newline-terminated, so we append `'\n'` to the input when
 * computing the expected output.
 *
 * V1 (`#if … #end` followed by a newline-and-indent before the next
 * modifier keyword) stays parse-only: preserving the inter-modifier
 * line break requires trivia capture on `HxMemberDecl.modifiers` (per-
 * element blank/newline slots) plus the bearing cascade on
 * `HxModifier`. The multi-line V4 variant (cond / modifier / `#end`
 * on separate lines) has the same prerequisite. Both are deferred.
 */
class CondModProbe extends Test {

	private static final _forceBuildParser:Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;
	private static final _forceBuildWriter:Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	public function testIssue107():Void {
		roundTrip('class Main {\n\t#if !cppia inline #end function addChar(c:Int):Void {}\n}');
	}

	public function testIssue291():Void {
		roundTrip('class Xml {\n\tvar nodeName:String = "";\n\n\t#if !cppia inline #end function get_nodeName() {\n\t\treturn nodeName;\n\t}\n}');
	}

	public function testIssue332V1():Void {
		final src:String = 'class Main {\n\t#if (neko_v21 || (cpp && !cppia) || flash) inline #end\n\tpublic static function main() {}\n}';
		HaxeModuleTriviaParser.parse(src);
		Assert.pass();
	}

	public function testIssue332V2():Void {
		roundTrip('class Main {\n\t#if (neko_v21 || (cpp && !cppia) || flash) inline #end public static function main() {}\n}');
	}

	public function testIssue332V3():Void {
		roundTrip('class Main {\n\tpublic static #if (neko_v21 || (cpp && !cppia) || flash) inline #end function main() {}\n}');
	}

	private static function roundTrip(source:String):Void {
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(source + '\n', out);
	}
}

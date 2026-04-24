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
 * and `issue_332_conditional_modifiers` (V1–V4).
 *
 * Single-line variants (V2, V3, `issue_107`, `issue_291`) and V1 assert
 * that the input parses AND that `parse → write` round-trips byte-
 * exactly. V2 / V3 use the writer-side gate closed by
 * `@:fmt(padBoundaries)` on `HxConditionalMod.body` (cond↔body[0] and
 * body[last]↔`#end` boundary spaces). V1 (`#if … #end` followed by a
 * newline-and-indent before the next modifier keyword) uses the
 * `@:trivia` capture added on `HxMemberDecl.modifiers` (per-element
 * `newlineBefore` slot consumed by the trivia tryparse Star writer to
 * emit a hardline between modifiers when the source had a single
 * newline boundary).
 *
 * V4 (cond / modifier / `#end` on separate lines) stays parse-only:
 * the newlines INSIDE `HxConditionalMod.body` (between cond / body[0]
 * and between body[last] / `#end`) require the bearing cascade onto
 * `HxModifier` plus a padBoundaries-aware trivia writer plus a
 * trail-side newline capture on the outer `Conditional` ctor. Deferred
 * until those land as their own slice — the V1 fix already removes the
 * primary corpus byte-diff (`issue_332` advances from offset 68 to
 * offset 327 with V4 as the lone remaining gap).
 *
 * The fork fixtures' output sections are trailing-newline-terminated,
 * so `roundTrip` appends `'\n'` to the input when computing the
 * expected output.
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
		roundTrip('class Main {\n\t#if (neko_v21 || (cpp && !cppia) || flash) inline #end\n\tpublic static function main() {}\n}');
	}

	public function testIssue332V2():Void {
		roundTrip('class Main {\n\t#if (neko_v21 || (cpp && !cppia) || flash) inline #end public static function main() {}\n}');
	}

	public function testIssue332V3():Void {
		roundTrip('class Main {\n\tpublic static #if (neko_v21 || (cpp && !cppia) || flash) inline #end function main() {}\n}');
	}

	public function testIssue332V4():Void {
		HaxeModuleTriviaParser.parse('class Main {\n\t#if (neko_v21 || (cpp && !cppia) || flash)\n\tinline\n\t#end\n\tpublic static function main() {}\n}');
		Assert.pass();
	}

	private static function roundTrip(source:String):Void {
		final ast:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(source + '\n', out);
	}
}

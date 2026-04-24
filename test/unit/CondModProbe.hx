package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;

/**
 * Regression guard for slice ω-if-modifier — `#if COND <modifiers> #end`
 * interleaved with regular modifiers inside a class-member modifier
 * list. Covers the five single-line positional variants observed in the
 * haxe-formatter fixtures `issue_107_inline_sharp`,
 * `issue_291_conditional_modifier`, and `issue_332_conditional_modifiers`
 * (V1–V3).
 *
 * The multi-line variant of `issue_332` (V4 — `cond`, modifier, and
 * `#end` on separate lines) is intentionally NOT in this guard: it
 * requires the body Star to opt into `@:trivia` capture plus the
 * bearing cascade on `HxModifier`, which is out of scope for this
 * slice.
 */
class CondModProbe extends Test {

	private static final _forceBuild:Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;

	public function testIssue107():Void {
		final src:String = 'class Main {\n\t#if !cppia inline #end function addChar(c:Int):Void {}\n}';
		HaxeModuleTriviaParser.parse(src);
		Assert.pass();
	}

	public function testIssue291():Void {
		final src:String = 'class Xml {\n\tvar nodeName:String = "";\n\n\t#if !cppia inline #end function get_nodeName() {\n\t\treturn nodeName;\n\t}\n}';
		HaxeModuleTriviaParser.parse(src);
		Assert.pass();
	}

	public function testIssue332V1():Void {
		final src:String = 'class Main {\n\t#if (neko_v21 || (cpp && !cppia) || flash) inline #end\n\tpublic static function main() {}\n}';
		HaxeModuleTriviaParser.parse(src);
		Assert.pass();
	}

	public function testIssue332V2():Void {
		final src:String = 'class Main {\n\t#if (neko_v21 || (cpp && !cppia) || flash) inline #end public static function main() {}\n}';
		HaxeModuleTriviaParser.parse(src);
		Assert.pass();
	}

	public function testIssue332V3():Void {
		final src:String = 'class Main {\n\tpublic static #if (neko_v21 || (cpp && !cppia) || flash) inline #end function main() {}\n}';
		HaxeModuleTriviaParser.parse(src);
		Assert.pass();
	}
}

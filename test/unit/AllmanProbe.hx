package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;

/**
 * Regression guard — Allman brace (next-line `{`) parses on the
 * structural forms where `@:lead('{')` appears. Pre-field `skipWs`
 * (Lowering.hx:1042) consumes `\n` before the lead, so no parser
 * change is needed for these shapes.
 */
class AllmanProbe extends Test {

	private static final _forceBuild:Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;

	public function testAllmanEmptyClass():Void {
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse('class Main\n{\n}');
		Assert.equals(1, m.decls.length);
	}

	public function testAllmanClassWithMember():Void {
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse('class Main\n{\n\tstatic function main() {}\n}');
		Assert.equals(1, m.decls.length);
	}

	public function testAllmanFunctionBody():Void {
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse('class C {\n\tstatic function m()\n\t{\n\t}\n}');
		Assert.equals(1, m.decls.length);
	}

	public function testAllmanIfBody():Void {
		HaxeModuleTriviaParser.parse('class C{static function m(){if(x)\n{a();}}}');
		Assert.pass();
	}

	public function testAllmanWhileBody():Void {
		HaxeModuleTriviaParser.parse('class C{static function m(){while(x)\n{a();}}}');
		Assert.pass();
	}

	public function testAllmanForBody():Void {
		HaxeModuleTriviaParser.parse('class C{static function m(){for(i in x)\n{a();}}}');
		Assert.pass();
	}

	public function testAllmanSwitchBody():Void {
		HaxeModuleTriviaParser.parse('class C{static function m(){switch(x)\n{case 1:a();}}}');
		Assert.pass();
	}
}

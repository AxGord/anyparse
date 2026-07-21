package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModule;

/**
 * Tests for a MULTI-param `#else` body in `HxConditionalParam` — the
 * `@:sep(',', sepFaithful)` on `elseBody`. Without the flag the field
 * carried no separator at all, so the body fail-rewound after its first
 * param and only the single-param case parsed.
 *
 * Both remaining openfl constructors blocked on parameter-scope
 * conditionals need the multi-param form: `TextLayout.new` (three params
 * in the `#else` arm) and `Stage.new` (two). The `#if` arm already
 * accepted several params through the non-kw-led `body` Star, which is
 * why the asymmetry went unnoticed.
 */
class HxCondParamElseSepSliceTest extends HxTestHelpers {

	public function testMultiParamElseBodyParses(): Void {
		final src: String = 'class C {\n\tfunction f(#if a x:Int #else y:Int, z:Int #end):Void {}\n}';
		Assert.equals(1, HaxeModuleParser.parse(src).decls.length);
		roundTrip(src, 'multi-param #else');
	}

	public function testOpenflTextLayoutSignature(): Void {
		final params: String = 'text:String = "", font:Font = null, size:Int = 12, '
			+ '#if (!hl) direction:TextDirection = INVALID, script:TextScript = GUESS, language:String = "" '
			+ '#else direction:TextDirection = LEFT_TO_RIGHT, script:TextScript = COMMON, language:String = "en" #end';
		assertSignatureRoundTrips(params);
	}

	public function testOpenflStageSignature(): Void {
		final params: String = '#if commonjs width:Dynamic = 0, height:Dynamic = 0, color:Null<Int> = null, '
			+ 'documentClass:Class<Dynamic> = null, windowAttributes:Dynamic = null ' + '#else window:Window, color:Null<Int> = null #end';
		assertSignatureRoundTrips(params);
	}

	public function testElseifArmTakesSeveralParams(): Void {
		final src: String = 'class C {\n\tfunction f(#if a x:Int #elseif b y:Int, z:Int #else w:Int, v:Int #end):Void {}\n}';
		Assert.equals(1, HaxeModuleParser.parse(src).decls.length);
		roundTrip(src, 'multi-param #elseif and #else');
	}

	public function testSingleParamAndUnguardedFormsUnaffected(): Void {
		for (params in ['#if a x:Int #else y:Int #end', 'a:Int, #if x b:Int #end', 'a:Int, b:Int', '']) assertSignatureRoundTrips(params);
	}

	private function assertSignatureRoundTrips(params: String): Void {
		final src: String = 'class C {\n\tfunction f($params):Void {}\n}';
		final ast: HxModule = HaxeModuleParser.parse(src);
		Assert.equals(1, ast.decls.length, params);
		roundTrip(src, params);
	}

}

package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.WhitespacePolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * Slice ω-typeparam-spacing — runtime-switchable `typeParamOpen` and
 * `typeParamClose` whitespace policies for the `<>` of a type-parameter
 * list. Default `None`/`None` keeps `Array<Int>` and `class Foo<T>`
 * tight, matching haxe-formatter's
 * `whitespace.typeParamOpenPolicy: @:default(None)` and
 * `typeParamClosePolicy: @:default(None)`.
 *
 * The knobs are wired via `@:fmt(typeParamOpen, typeParamClose)` on
 * every Star site whose lead/trail is `<`/`>`: `HxTypeRef.params` plus
 * the declare-site `typeParams` fields on class / interface / abstract
 * / enum / typedef / function decls. The fixture
 * `issue_588_anon_type_param.hxtest` (haxe-formatter) drives
 * `typeParamOpen=After` + `typeParamClose=Before` to produce
 * `Array< {key:Int} >`.
 */
@:nullSafety(Strict)
final class HxTypeParamSpacingOptionsTest extends Test {

	public function new():Void {
		super();
	}

	public function testTypeParamOpenDefaultIsNone():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(WhitespacePolicy.None, defaults.typeParamOpen);
	}

	public function testTypeParamCloseDefaultIsNone():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(WhitespacePolicy.None, defaults.typeParamClose);
	}

	public function testTypeParamNoneKeepsTight():Void {
		final out:String = writeWith('typedef T = Array<Int>;', WhitespacePolicy.None, WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('typedef T = Array<Int>;') != -1, 'expected tight `Array<Int>` in: <$out>');
	}

	public function testTypeParamOpenAfterEmitsSpaceInsideAfterOpen():Void {
		final out:String = writeWith('typedef T = Array<Int>;', WhitespacePolicy.After, WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('Array< Int>') != -1, 'expected `Array< Int>` in: <$out>');
	}

	public function testTypeParamCloseBeforeEmitsSpaceInsideBeforeClose():Void {
		final out:String = writeWith('typedef T = Array<Int>;', WhitespacePolicy.None, WhitespacePolicy.Before);
		Assert.isTrue(out.indexOf('Array<Int >') != -1, 'expected `Array<Int >` in: <$out>');
	}

	public function testTypeParamBothEmitsSpaceInsideBothSides():Void {
		final out:String = writeWith('typedef T = Array<Int>;', WhitespacePolicy.After, WhitespacePolicy.Before);
		Assert.isTrue(out.indexOf('Array< Int >') != -1, 'expected `Array< Int >` in: <$out>');
	}

	public function testTypeParamBothPolicyEmitsBothSides():Void {
		final out:String = writeWith('typedef T = Array<Int>;', WhitespacePolicy.Both, WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('Array < Int >') != -1, 'expected `Array < Int >` in: <$out>');
	}

	public function testTypeParamOpenBeforeEmitsSpaceOutsideBeforeOpen():Void {
		final out:String = writeWith('typedef T = Array<Int>;', WhitespacePolicy.Before, WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('Array <Int>') != -1, 'expected `Array <Int>` in: <$out>');
	}

	public function testAnonStructInsideTypeParamsRoundTripsLikeFixture():Void {
		// Fixture issue_588_anon_type_param: `Array< {key:Int} >` round-trips
		// byte-perfect under `typeParamOpen=After` + `typeParamClose=Before`.
		final out:String = writeWith('typedef Type = Array<{key:Int}>;', WhitespacePolicy.After, WhitespacePolicy.Before);
		Assert.isTrue(out.indexOf('Array< {key:Int} >') != -1, 'expected `Array< {key:Int} >` in: <$out>');
	}

	public function testClassDeclTypeParamsHonorOpenAfter():Void {
		final out:String = writeWith('class Foo<T> {}', WhitespacePolicy.After, WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('class Foo< T>') != -1, 'expected `class Foo< T>` in: <$out>');
	}

	public function testTypedefDeclTypeParamsHonorBothInsideKnobs():Void {
		final out:String = writeWith('typedef Pair<A, B> = {a:A, b:B};', WhitespacePolicy.After, WhitespacePolicy.Before);
		Assert.isTrue(out.indexOf('typedef Pair< A, B >') != -1, 'expected `typedef Pair< A, B >` in: <$out>');
	}

	public function testJsonLoaderRoutesTypeParamPolicies():Void {
		final json:String = '{ "whitespace": { "typeParamOpenPolicy": "after", "typeParamClosePolicy": "before" } }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(json);
		Assert.equals(WhitespacePolicy.After, opts.typeParamOpen);
		Assert.equals(WhitespacePolicy.Before, opts.typeParamClose);
	}

	private inline function writeWith(src:String, open:WhitespacePolicy, close:WhitespacePolicy):String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), makeOpts(open, close));
	}

	private inline function makeOpts(open:WhitespacePolicy, close:WhitespacePolicy):HxModuleWriteOptions {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.typeParamOpen = open;
		opts.typeParamClose = close;
		return opts;
	}
}

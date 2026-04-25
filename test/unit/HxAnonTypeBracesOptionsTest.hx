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
 * Slice ω-anontype-braces — runtime-switchable `anonTypeBracesOpen`
 * and `anonTypeBracesClose` whitespace policies for the `{}` of an
 * anonymous structure type (`HxType.Anon`). Default `None`/`None`
 * keeps `{x:Int}` tight, matching haxe-formatter's
 * `bracesConfig.anonTypeBraces` defaults whose effective inside
 * spaces are also none.
 *
 * The knob is wired via `@:fmt(anonTypeBracesOpen, anonTypeBracesClose)`
 * on the `HxType.Anon` Alt-branch's `@:lead('{') @:trail('}')
 * @:sep(',')` Star, routed through `lowerEnumStar`'s sepList path
 * with the existing `delimInsidePolicySpace` helper. The fixture
 * `space_inside_anon_type_hint.hxtest` (haxe-formatter) drives
 * `openingPolicy: "around"` + `closingPolicy: "around"` to produce
 * `{ host:Host }`.
 */
@:nullSafety(Strict)
final class HxAnonTypeBracesOptionsTest extends Test {

	public function new():Void {
		super();
	}

	public function testAnonTypeBracesOpenDefaultIsNone():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(WhitespacePolicy.None, defaults.anonTypeBracesOpen);
	}

	public function testAnonTypeBracesCloseDefaultIsNone():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(WhitespacePolicy.None, defaults.anonTypeBracesClose);
	}

	public function testNoneKeepsTight():Void {
		final out:String = writeWith('typedef T = {x:Int};', WhitespacePolicy.None, WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('typedef T = {x:Int};') != -1, 'expected tight `{x:Int}` in: <$out>');
	}

	public function testOpenAfterEmitsSpaceInsideAfterOpen():Void {
		final out:String = writeWith('typedef T = {x:Int};', WhitespacePolicy.After, WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('{ x:Int}') != -1, 'expected `{ x:Int}` in: <$out>');
	}

	public function testCloseBeforeEmitsSpaceInsideBeforeClose():Void {
		final out:String = writeWith('typedef T = {x:Int};', WhitespacePolicy.None, WhitespacePolicy.Before);
		Assert.isTrue(out.indexOf('{x:Int }') != -1, 'expected `{x:Int }` in: <$out>');
	}

	public function testBothEmitsSpaceInsideBothSides():Void {
		final out:String = writeWith('typedef T = {x:Int};', WhitespacePolicy.After, WhitespacePolicy.Before);
		Assert.isTrue(out.indexOf('{ x:Int }') != -1, 'expected `{ x:Int }` in: <$out>');
	}

	public function testMultiFieldAnonHonorsBothSides():Void {
		final out:String = writeWith('typedef T = {x:Int, y:String};', WhitespacePolicy.After, WhitespacePolicy.Before);
		Assert.isTrue(out.indexOf('{ x:Int, y:String }') != -1, 'expected `{ x:Int, y:String }` in: <$out>');
	}

	public function testAroundFixtureRoundTripsLikeUpstream():Void {
		// haxe-formatter fixture `space_inside_anon_type_hint.hxtest` flips
		// `openingPolicy: "around"` + `closingPolicy: "around"` and expects
		// `{ host:Host }`. Both knobs map to `WhitespacePolicy.Both` —
		// outside-before on the Alt-branch path is no-op, the effective
		// emission is `inside-after-open` + `inside-before-close`.
		final out:String = writeWith('interface Test { public function peer():{host:Host}; }', WhitespacePolicy.Both, WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf(':{ host:Host }') != -1, 'expected `:{ host:Host }` in: <$out>');
	}

	public function testJsonLoaderRoutesAnonTypeBracesPolicies():Void {
		final json:String = '{ "whitespace": { "bracesConfig": { "anonTypeBraces": { "openingPolicy": "around", "closingPolicy": "around" } } } }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(json);
		Assert.equals(WhitespacePolicy.Both, opts.anonTypeBracesOpen);
		Assert.equals(WhitespacePolicy.Both, opts.anonTypeBracesClose);
	}

	public function testJsonLoaderIgnoresUnknownBracesKey():Void {
		// Sibling `removeInnerWhenEmpty` from haxe-formatter's schema is
		// silently ignored by the ByName parser's `UnknownPolicy.Skip` —
		// the loader still picks up the recognised opening/closing pair.
		final json:String = '{ "whitespace": { "bracesConfig": { "anonTypeBraces": { "openingPolicy": "after", "closingPolicy": "before", "removeInnerWhenEmpty": false } } } }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(json);
		Assert.equals(WhitespacePolicy.After, opts.anonTypeBracesOpen);
		Assert.equals(WhitespacePolicy.Before, opts.anonTypeBracesClose);
	}

	private inline function writeWith(src:String, open:WhitespacePolicy, close:WhitespacePolicy):String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), makeOpts(open, close));
	}

	private inline function makeOpts(open:WhitespacePolicy, close:WhitespacePolicy):HxModuleWriteOptions {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.anonTypeBracesOpen = open;
		opts.anonTypeBracesClose = close;
		return opts;
	}
}

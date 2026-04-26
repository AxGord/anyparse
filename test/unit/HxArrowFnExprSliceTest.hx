package unit;

import utest.Assert;
import anyparse.format.WhitespacePolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * Slice ω-arrow-fn-expr — parenthesised arrow lambda expression
 * `(params) -> body` `->` separator spacing.
 *
 * Mirror of ω-arrow-fn-type (the type-position sibling): a new
 * `arrowFunctions:WhitespacePolicy` knob on `HxModuleWriteOptions`
 * (default `Both`) routes `HxThinParenLambda.body`'s `@:lead('->')`
 * through `whitespacePolicyLead`. Parser side is unchanged — slice is
 * purely writer + config plumbing.
 *
 * Default `Both` matches haxe-formatter's
 * `whitespace.arrowFunctionsPolicy: @:default(Around)` and emits
 * `(arg) -> body` with surrounding spaces. Setting the runtime policy
 * to `None` produces the tight pre-slice layout `(arg)->body`.
 *
 * Independent of `functionTypeHaxe4` (the type-position knob on
 * `HxArrowFnType.ret`) so a config can space one form while keeping
 * the other tight, mirroring upstream's separate JSON keys. The
 * single-ident infix form `arg -> body` (`HxExpr.ThinArrow`) rides
 * the Pratt infix path which already adds surrounding spaces by
 * default and is unaffected by this knob.
 */
@:nullSafety(Strict)
class HxArrowFnExprSliceTest extends HxTestHelpers {

	public function testWriterEmitsAroundSpacedZeroParam():Void {
		final out:String = writeWith('class C { var f:Int = ()->42; }', WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('= () -> 42;') != -1, 'expected `() -> 42` in: <$out>');
	}

	public function testWriterEmitsAroundSpacedSingleParam():Void {
		final out:String = writeWith('class C { var f:Int = (x)->x + 1; }', WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('= (x) -> x + 1;') != -1, 'expected `(x) -> x + 1` in: <$out>');
	}

	public function testWriterEmitsAroundSpacedMultiParam():Void {
		final out:String = writeWith('class C { var f:Int = (x,y)->x + y; }', WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('= (x, y) -> x + y;') != -1, 'expected `(x, y) -> x + y` in: <$out>');
	}

	public function testWriterEmitsAroundSpacedTypedParam():Void {
		final out:String = writeWith('class C { var f:Int = (x:Int)->x; }', WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('= (x:Int) -> x;') != -1, 'expected `(x:Int) -> x` in: <$out>');
	}

	public function testWriterTightWhenPolicyNone():Void {
		final out:String = writeWith('class C { var f:Int = (x) -> x + 1; }', WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('= (x)->x + 1;') != -1, 'expected `(x)->x + 1` in: <$out>');
		Assert.isTrue(out.indexOf(') -> x + 1') == -1, 'did not expect spaced `->` in: <$out>');
	}

	public function testWriterTightZeroParamWhenPolicyNone():Void {
		final out:String = writeWith('class C { var f:Int = () -> 42; }', WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('= ()->42;') != -1, 'expected `()->42` in: <$out>');
	}

	public function testThinArrowInfixUnaffected():Void {
		// Single-ident infix form `arg -> body` rides the Pratt infix
		// path which adds surrounding spaces by default; the new knob
		// does NOT reach this site, so it stays around-spaced even
		// under `WhitespacePolicy.None`.
		final out:String = writeWith('class C { var f:Int = arg -> arg + 1; }', WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('= arg -> arg + 1;') != -1, 'expected `arg -> arg + 1` in: <$out>');
	}

	public function testFunctionTypeHaxe4UnaffectedByArrowFunctions():Void {
		// `functionTypeHaxe4` (type-position) is independent of
		// `arrowFunctions` (expression-position): the knobs target
		// different `@:fmt(...)` flags and different grammar sites.
		// Setting `arrowFunctions=None` must not collapse the
		// type-position arrow's spacing.
		final src:String = 'class C { var f:(Int) -> Bool; }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.arrowFunctions = WhitespacePolicy.None;
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		Assert.isTrue(out.indexOf('var f:(Int) -> Bool;') != -1, 'expected `(Int) -> Bool` in: <$out>');
	}

	public function testArrowFunctionsDefaultIsBoth():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(WhitespacePolicy.Both, defaults.arrowFunctions);
	}

	public function testArrowFunctionsLoaderMapsAround():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"whitespace":{"arrowFunctionsPolicy":"around"}}'
		);
		Assert.equals(WhitespacePolicy.Both, opts.arrowFunctions);
	}

	public function testArrowFunctionsLoaderMapsNone():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"whitespace":{"arrowFunctionsPolicy":"none"}}'
		);
		Assert.equals(WhitespacePolicy.None, opts.arrowFunctions);
	}

	public function testArrowFunctionsLoaderMapsBefore():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"whitespace":{"arrowFunctionsPolicy":"before"}}'
		);
		Assert.equals(WhitespacePolicy.Before, opts.arrowFunctions);
	}

	public function testArrowFunctionsLoaderMapsAfter():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"whitespace":{"arrowFunctionsPolicy":"after"}}'
		);
		Assert.equals(WhitespacePolicy.After, opts.arrowFunctions);
	}

	public function testRoundTrip():Void {
		roundTrip('class C { var f:Int = () -> 42; }', 'zero-param');
		roundTrip('class C { var f:Int = (x) -> x + 1; }', 'single-param');
		roundTrip('class C { var f:Int = (x, y) -> x + y; }', 'multi-param');
		roundTrip('class C { var f:Int = (x:Int) -> x; }', 'typed-param');
		roundTrip('class C { var f:Int = (x:Int, y:String) -> x; }', 'multi-typed');
		roundTrip('class C { function f():Int { return (x) -> x; } }', 'in-return');
	}

	private inline function writeWith(src:String, policy:WhitespacePolicy):String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), makeOpts(policy));
	}

	private inline function makeOpts(policy:WhitespacePolicy):HxModuleWriteOptions {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.arrowFunctions = policy;
		return opts;
	}
}

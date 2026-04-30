package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeTypeRewrites;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.haxe.HxType;

/**
 * ω-fmt-prewrite-hook + ω-arrow-fn-old-style — unit coverage for
 * `HaxeTypeRewrites.arrowFnOldStyleRewrite` (the structural rewrite
 * function) AND the end-to-end writer integration via the macro
 * `@:fmt(preWrite('...'))` hook on `HxType.ArrowFn`.
 *
 * The rewrite collapses `ArrowFn([Positional(Arrow(_,_))], ret)` to
 * `Arrow(Parens(inner), ret)` so the writer emits the tight old-style
 * curried-chain form. See `HaxeTypeRewrites.hx` doc for the detection
 * rule. Closes corpus fixtures `issue_56_arrow_functions` and
 * `issue_92_detect_function_style`.
 */
@:nullSafety(Strict)
class HxArrowFnOldStyleRewriteTest extends HxTestHelpers {

	// ---- Direct rewrite unit tests ----

	public function testRewriteSinglePositionalArrow():Void {
		// `(Int->Int) -> Int` → `Arrow(Parens(Arrow(Int,Int)), Int)`.
		final input:HxType = ArrowFn({
			args: [Positional(Arrow(named('Int'), named('Int')))],
			ret: named('Int'),
		});
		final out:Null<HxType> = HaxeTypeRewrites.arrowFnOldStyleRewrite(input, makeOpts());
		Assert.notNull(out);
		switch out {
			case Arrow(Parens(Arrow(_, _)), Named(_)): Assert.pass();
			case _: Assert.fail('expected Arrow(Parens(Arrow), Named), got $out');
		}
	}

	public function testRewriteSinglePositionalNonArrowReturnsNull():Void {
		// `(Int) -> Int` — single Positional but inner is Named, NOT
		// Arrow. Rewrite must return null (writer keeps default
		// ArrowFn emission, around-spaced).
		final input:HxType = ArrowFn({
			args: [Positional(named('Int'))],
			ret: named('Int'),
		});
		Assert.isNull(HaxeTypeRewrites.arrowFnOldStyleRewrite(input, makeOpts()));
	}

	public function testRewriteSingleNamedReturnsNull():Void {
		final input:HxType = ArrowFn({
			args: [Named({name: 'x', type: named('String')})],
			ret: named('Void'),
		});
		Assert.isNull(HaxeTypeRewrites.arrowFnOldStyleRewrite(input, makeOpts()));
	}

	public function testRewriteMultiArgReturnsNull():Void {
		final input:HxType = ArrowFn({
			args: [Positional(named('Int')), Positional(named('String'))],
			ret: named('Bool'),
		});
		Assert.isNull(HaxeTypeRewrites.arrowFnOldStyleRewrite(input, makeOpts()));
	}

	public function testRewriteEmptyArgsReturnsNull():Void {
		final input:HxType = ArrowFn({args: [], ret: named('Void')});
		Assert.isNull(HaxeTypeRewrites.arrowFnOldStyleRewrite(input, makeOpts()));
	}

	public function testRewriteNonArrowFnCtorsReturnNull():Void {
		final opts:HxModuleWriteOptions = makeOpts();
		Assert.isNull(HaxeTypeRewrites.arrowFnOldStyleRewrite(named('Int'), opts));
		Assert.isNull(HaxeTypeRewrites.arrowFnOldStyleRewrite(Arrow(named('A'), named('B')), opts));
		Assert.isNull(HaxeTypeRewrites.arrowFnOldStyleRewrite(Parens(named('A')), opts));
	}

	// ---- Writer integration via @:fmt(preWrite) hook ----

	public function testWriterEmitsTightOldStyleChain():Void {
		// haxe-formatter canonical: `(Int->Int)->Int->Int` (fully tight).
		// Pre-fix output: `(Int->Int) -> Int->Int` (ArrowFn around-spaced
		// outer arrow, mixed with tight inner Arrow).
		final out:String = writeDefault('class Foo { var f:(Int->Int) -> Int->Int; }');
		Assert.isTrue(out.indexOf('var f:(Int->Int)->Int->Int;') != -1,
			'expected tight `(Int->Int)->Int->Int`, got: <$out>');
	}

	public function testWriterEmitsTightCurriedChain():Void {
		// `(R->Void)->(E<X>->Void)->Void` from `issue_92_detect_function_style`.
		final out:String = writeDefault('class Foo { var f:(R->Void)->(E<X>->Void)->Void; }');
		Assert.isTrue(out.indexOf('var f:(R->Void)->(E<X>->Void)->Void;') != -1,
			'expected fully tight chain, got: <$out>');
	}

	public function testWriterPreservesAroundSpacedNewStyle():Void {
		// `(Int) -> Int` — single Positional Named, must NOT be
		// rewritten; writer keeps around-spaced ` -> ` per the
		// default `functionTypeHaxe4 = Both`.
		final out:String = writeDefault('class Foo { var f:(Int) -> Int; }');
		Assert.isTrue(out.indexOf('var f:(Int) -> Int;') != -1,
			'expected around-spaced `(Int) -> Int`, got: <$out>');
	}

	public function testWriterPreservesAroundSpacedNamedArg():Void {
		final out:String = writeDefault('class Foo { var f:(name:String) -> Void; }');
		Assert.isTrue(out.indexOf('var f:(name:String) -> Void;') != -1,
			'expected `(name:String) -> Void`, got: <$out>');
	}

	public function testWriterPreservesAroundSpacedMultiArg():Void {
		final out:String = writeDefault('class Foo { var f:(Int, String) -> Bool; }');
		Assert.isTrue(out.indexOf('var f:(Int, String) -> Bool;') != -1,
			'expected `(Int, String) -> Bool`, got: <$out>');
	}

	public function testWriterPreservesEmptyParens():Void {
		final out:String = writeDefault('class Foo { var f:() -> Void; }');
		Assert.isTrue(out.indexOf('var f:() -> Void;') != -1,
			'expected `() -> Void`, got: <$out>');
	}

	public function testRoundTripIdempotency():Void {
		// After the rewrite, output must be a fixed point — re-parse
		// + re-write produces identical bytes.
		roundTrip('class Foo { var f:(Int->Int)->Int->Int; }', 'tight-old-style');
		roundTrip('class Foo { var f:(R->Void)->(E<X>->Void)->Void; }', 'curried-chain');
		roundTrip('class Foo { var f:(Int) -> Int; }', 'new-style-single-pos');
		roundTrip('class Foo { var f:(name:String) -> Void; }', 'new-style-named');
	}

	// ---- helpers ----

	private inline function named(name:String):HxType {
		return Named({name: name, params: null});
	}

	private inline function makeOpts():HxModuleWriteOptions {
		return HaxeFormatConfigLoader.loadHxFormatJson('{}');
	}

	private inline function writeDefault(src:String):String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), makeOpts());
	}
}

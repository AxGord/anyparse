package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * ω-anon-fn-empty-paren-inner-space — runtime-switchable inside-of-
 * empty-paren padding for anonymous-function parameter lists. When
 * `anonFuncParamParensKeepInnerWhenEmpty` is `true`, an empty
 * `HxFnExpr.params` Star emits `function ( ) body` instead of the
 * default tight `function() body`. Routed through `WriterCodegen`'s
 * `sepList` `keepInnerWhenEmpty` argument and read from
 * `@:fmt(keepInnerWhenEmpty('anonFuncParamParensKeepInnerWhenEmpty'))`.
 *
 * Loader inverts haxe-formatter's `removeInnerWhenEmpty` semantic:
 * `false` in JSON → `true` in opt (the writer keeps the inside space).
 * Default `true` in JSON / `false` in opt collapses to `function()` —
 * matching the pre-slice output for every fixture that does not opt in.
 */
@:nullSafety(Strict)
class HxAnonFuncEmptyParensInnerSpaceOptionsTest extends Test {

	public function new():Void {
		super();
	}

	public function testDefaultIsCollapsed():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.isFalse(defaults.anonFuncParamParensKeepInnerWhenEmpty);
	}

	public function testDefaultEmitsTightEmptyParens():Void {
		final out:String = writeWith('class C { static function m() { call(function() trace(0)); } }', false);
		Assert.isTrue(out.indexOf('function()') != -1, 'expected `function()` in: <$out>');
		Assert.isTrue(out.indexOf('function ( )') == -1, 'did not expect `function ( )` in: <$out>');
	}

	public function testKeepInnerEmitsSpace():Void {
		// `anonFuncParens` defaults to `None`, so the space between
		// `function` and `(` stays absent — the knob under test only
		// gates the inside-of-parens slot. Combined with
		// `anonFuncParens = Before` callers reproduce the full
		// `issue_251` shape `function ( )`; here we assert just the
		// inside-empty slot.
		final out:String = writeWith('class C { static function m() { call(function() trace(0)); } }', true);
		Assert.isTrue(out.indexOf('function( )') != -1, 'expected `function( )` in: <$out>');
	}

	public function testKeepInnerCombinedWithBeforeProducesIssue251Shape():Void {
		// Full `issue_251` shape requires both knobs: outside-before-`(`
		// space (anonFuncParens = Before) AND inside-of-empty-`(` space
		// (anonFuncParamParensKeepInnerWhenEmpty = true).
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.anonFuncParens = anyparse.format.WhitespacePolicy.Before;
		opts.anonFuncParamParensKeepInnerWhenEmpty = true;
		final out:String = HxModuleWriter.write(
			HaxeModuleParser.parse('class C { static function m() { call(function() trace(0)); } }'), opts);
		Assert.isTrue(out.indexOf('function ( )') != -1, 'expected `function ( )` in: <$out>');
	}

	public function testNonEmptyParamsUnaffected():Void {
		// Knob targets the empty-list short-circuit only; a non-empty
		// param list keeps the regular `(p)` shape under either setting.
		for (keep in [false, true]) {
			final out:String = writeWith('class C { static function m() { call(function(p) trace(p)); } }', keep);
			Assert.isTrue(out.indexOf('function(p)') != -1,
				'expected tight `function(p)` under keepInnerWhenEmpty=$keep in: <$out>');
		}
	}

	public function testFnDeclUnaffected():Void {
		// Knob is bound to `HxFnExpr.params` only; declaration-form
		// `HxFnDecl.params` keeps the tight `m()` regardless.
		for (keep in [false, true]) {
			final out:String = writeWith('class C { static function m() { trace(0); } }', keep);
			Assert.isTrue(out.indexOf('function m()') != -1,
				'fn-decl `function m()` should stay tight under keep=$keep in: <$out>');
			Assert.isTrue(out.indexOf('function m( )') == -1,
				'fn-decl must not pick up the anon-fn knob under keep=$keep in: <$out>');
		}
	}

	public function testJsonRemoveInnerFalseKeepsSpace():Void {
		// haxe-formatter `removeInnerWhenEmpty: false` inverts to opt = true.
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"whitespace": {"parenConfig": {"anonFuncParamParens": {"removeInnerWhenEmpty": false}}}}');
		Assert.isTrue(opts.anonFuncParamParensKeepInnerWhenEmpty);
	}

	public function testJsonRemoveInnerTrueCollapses():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"whitespace": {"parenConfig": {"anonFuncParamParens": {"removeInnerWhenEmpty": true}}}}');
		Assert.isFalse(opts.anonFuncParamParensKeepInnerWhenEmpty);
	}

	public function testJsonAbsentLeavesDefault():Void {
		// Sibling keys (openingPolicy) must not flip the knob.
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"whitespace": {"parenConfig": {"anonFuncParamParens": {"openingPolicy": "before"}}}}');
		Assert.isFalse(opts.anonFuncParamParensKeepInnerWhenEmpty);
	}

	public function testJsonOpeningAndKeepInnerIndependent():Void {
		// Setting both keys propagates both runtime fields independently.
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"whitespace": {"parenConfig": {"anonFuncParamParens": {"openingPolicy": "before", "removeInnerWhenEmpty": false}}}}');
		Assert.isTrue(opts.anonFuncParamParensKeepInnerWhenEmpty);
		Assert.equals(anyparse.format.WhitespacePolicy.Before, opts.anonFuncParens);
	}

	private inline function writeWith(src:String, keepInner:Bool):String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), makeOpts(keepInner));
	}

	private inline function makeOpts(keepInner:Bool):HxModuleWriteOptions {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.anonFuncParamParensKeepInnerWhenEmpty = keepInner;
		return opts;
	}
}

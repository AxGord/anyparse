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
 * ω-anon-fn-paren-policy — runtime-switchable `anonFuncParens`
 * whitespace policy for the gap between the `function` keyword and
 * the opening `(` of an anonymous-function expression
 * (`HxExpr.FnExpr(fn:HxFnExpr)`). Wired via
 * `WriterLowering.kwTrailingSpacePolicy` (kw-side mirror of
 * `openDelimPolicySpace`), independent of `funcParamParens` (which
 * gates `HxFnDecl.params`'s `(` on declarations).
 *
 * `WhitespacePolicy.None` (default) emits tight `function(args)…`,
 * matching haxe-formatter's
 * `whitespace.parenConfig.anonFuncParamParens.openingPolicy:
 * @:default(auto)` when the `auto` heuristic collapses to no-space
 * (the heuristic itself is not modelled). `Before` / `Both` emit
 * `function (args)…`, matching `"before"`. `After` is accepted for
 * surface parity but produces no space — the kw-trailing slot is the
 * only switchable axis here.
 *
 * Independence from `funcParamParens` is asserted explicitly: flipping
 * one knob does not affect the other's spacing.
 */
@:nullSafety(Strict)
class HxAnonFuncParensOptionsTest extends Test {

	public function new():Void {
		super();
	}

	public function testAnonFuncParensDefaultIsNone():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(WhitespacePolicy.None, defaults.anonFuncParens);
	}

	public function testAnonNoneCollapsesGap():Void {
		final out:String = writeWith('class C { static function m() { handle(function() trace(0)); } }', WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('function()') != -1, 'expected `function()` in: <$out>');
		Assert.isTrue(out.indexOf('function ()') == -1, 'did not expect `function ()` in: <$out>');
	}

	public function testAnonBeforeEmitsSpace():Void {
		final out:String = writeWith('class C { static function m() { handle(function() trace(0)); } }', WhitespacePolicy.Before);
		Assert.isTrue(out.indexOf('function ()') != -1, 'expected `function ()` in: <$out>');
	}

	public function testAnonBothEmitsSpace():Void {
		final out:String = writeWith('class C { static function m() { handle(function() trace(0)); } }', WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('function ()') != -1, 'expected `function ()` in: <$out>');
	}

	public function testAnonAfterCollapsesGap():Void {
		final out:String = writeWith('class C { static function m() { handle(function() trace(0)); } }', WhitespacePolicy.After);
		Assert.isTrue(out.indexOf('function()') != -1, 'expected `function()` in: <$out>');
	}

	public function testAnonWithParamsNone():Void {
		final out:String = writeWith('class C { static function m() { call(function(r) trace(r)); } }', WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('function(r)') != -1, 'expected `function(r)` in: <$out>');
	}

	public function testAnonWithParamsBefore():Void {
		final out:String = writeWith('class C { static function m() { call(function(r) trace(r)); } }', WhitespacePolicy.Before);
		Assert.isTrue(out.indexOf('function (r)') != -1, 'expected `function (r)` in: <$out>');
	}

	public function testFnDeclUnaffectedByAnonFuncParens():Void {
		// Declaration-form `function m()` follows `funcParamParens` (None
		// by default), independent of `anonFuncParens`. Flipping the anon
		// knob to Before must NOT add a space inside the declaration.
		for (policy in [WhitespacePolicy.None, WhitespacePolicy.Before, WhitespacePolicy.After, WhitespacePolicy.Both]) {
			final out:String = writeWith('class C { static function m() { trace(0); } }', policy);
			Assert.isTrue(out.indexOf('function m()') != -1,
				'fn-decl `function m()` should stay tight under anonFuncParens=$policy in: <$out>');
		}
	}

	public function testJsonBeforeMapsToBefore():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"whitespace": {"parenConfig": {"anonFuncParamParens": {"openingPolicy": "before"}}}}');
		Assert.equals(WhitespacePolicy.Before, opts.anonFuncParens);
	}

	public function testJsonAroundMapsToBoth():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"whitespace": {"parenConfig": {"anonFuncParamParens": {"openingPolicy": "around"}}}}');
		Assert.equals(WhitespacePolicy.Both, opts.anonFuncParens);
	}

	public function testJsonNoneMapsToNone():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"whitespace": {"parenConfig": {"anonFuncParamParens": {"openingPolicy": "none"}}}}');
		Assert.equals(WhitespacePolicy.None, opts.anonFuncParens);
	}

	public function testJsonOnlyBeforeMapsToBefore():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"whitespace": {"parenConfig": {"anonFuncParamParens": {"openingPolicy": "onlyBefore"}}}}');
		Assert.equals(WhitespacePolicy.Before, opts.anonFuncParens);
	}

	public function testJsonAnonAndFuncParamIndependent():Void {
		// Setting only anonFuncParens via JSON must not alter funcParamParens.
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"whitespace": {"parenConfig": {"anonFuncParamParens": {"openingPolicy": "before"}}}}');
		Assert.equals(WhitespacePolicy.Before, opts.anonFuncParens);
		Assert.equals(WhitespacePolicy.None, opts.funcParamParens);
	}

	private inline function writeWith(src:String, anonPolicy:WhitespacePolicy):String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), makeOpts(anonPolicy));
	}

	private inline function makeOpts(anonPolicy:WhitespacePolicy):HxModuleWriteOptions {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.anonFuncParens = anonPolicy;
		return opts;
	}
}

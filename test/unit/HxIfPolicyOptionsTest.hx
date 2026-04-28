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
 * ω-if-policy — runtime-switchable `ifPolicy` whitespace policy for the
 * gap between the `if` keyword and the opening `(` of its condition.
 * Consumed by both `HxStatement.IfStmt` and `HxExpr.IfExpr` via
 * `@:fmt(ifPolicy)` on the ctor. `WhitespacePolicy.After` (default)
 * emits `if (cond)`, matching haxe-formatter's effective default and
 * the pre-slice fixed trailing space on the `if` keyword. `Before` /
 * `None` (mapped from JSON `"onlyBefore"` / `"none"`) collapse the gap
 * to `if(cond)`, matching `whitespace.ifPolicy: "onlyBefore"`.
 *
 * The knob is wired via `WriterLowering.kwTrailingSpacePolicy`
 * (mirror of `openDelimPolicySpace` for the kw side). Non-policy
 * branches (`else`, `for`, `while`, `switch`, `catch`, …) keep the
 * pre-slice fixed `kw + ' '` emission because their ctors carry no
 * `@:fmt(...)` flag — covered by regression assertions below.
 *
 * Tests assert the substring pattern that distinguishes each policy,
 * tolerant of unrelated layout so the assertions stay robust against
 * future layout tweaks.
 */
@:nullSafety(Strict)
class HxIfPolicyOptionsTest extends Test {

	public function new():Void {
		super();
	}

	public function testIfPolicyDefaultIsAfter():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(WhitespacePolicy.After, defaults.ifPolicy);
	}

	public function testIfStmtAfterEmitsSpaceBeforeParen():Void {
		final out:String = writeWith('class C { static function m() { if (a) b; } }', WhitespacePolicy.After);
		Assert.isTrue(out.indexOf('if (a)') != -1, 'expected `if (a)` in: <$out>');
	}

	public function testIfStmtNoneCollapsesGap():Void {
		final out:String = writeWith('class C { static function m() { if (a) b; } }', WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('if(a)') != -1, 'expected `if(a)` in: <$out>');
		Assert.isTrue(out.indexOf('if (') == -1, 'did not expect `if (` in: <$out>');
	}

	public function testIfStmtBeforeCollapsesGap():Void {
		// Before-after-kw means no space follows `if`; the before-`if` slot
		// is already provided by the preceding statement separator.
		final out:String = writeWith('class C { static function m() { if (a) b; } }', WhitespacePolicy.Before);
		Assert.isTrue(out.indexOf('if(a)') != -1, 'expected `if(a)` in: <$out>');
	}

	public function testIfStmtBothMatchesAfter():Void {
		final out:String = writeWith('class C { static function m() { if (a) b; } }', WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('if (a)') != -1, 'expected `if (a)` in: <$out>');
	}

	public function testIfExprNoneCollapsesGap():Void {
		final out:String = writeWith('class C { static function m() return if (a) b else c; }', WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('if(a)') != -1, 'expected `if(a)` in expression position: <$out>');
	}

	public function testIfExprAfterEmitsSpace():Void {
		final out:String = writeWith('class C { static function m() return if (a) b else c; }', WhitespacePolicy.After);
		Assert.isTrue(out.indexOf('if (a)') != -1, 'expected `if (a)` in expression position: <$out>');
	}

	public function testElseKwUnaffectedByIfPolicy():Void {
		// `else` ctor has no `@:fmt(ifPolicy)`, so its kw trailing space
		// must stay fixed regardless of the configured policy.
		for (policy in [WhitespacePolicy.None, WhitespacePolicy.Before, WhitespacePolicy.After, WhitespacePolicy.Both]) {
			final out:String = writeWith('class C { static function m() { if (a) b; else c; } }', policy);
			Assert.isTrue(out.indexOf('else c') != -1 || out.indexOf('else\n') != -1,
				'else kw should keep trailing layout under policy $policy in: <$out>');
		}
	}

	public function testForKwUnaffectedByIfPolicy():Void {
		for (policy in [WhitespacePolicy.None, WhitespacePolicy.Before, WhitespacePolicy.After, WhitespacePolicy.Both]) {
			final out:String = writeWith('class C { static function m() { for (i in 0...10) trace(i); } }', policy);
			Assert.isTrue(out.indexOf('for (i in') != -1,
				'for kw should keep trailing space under policy $policy in: <$out>');
		}
	}

	public function testWhileKwUnaffectedByIfPolicy():Void {
		for (policy in [WhitespacePolicy.None, WhitespacePolicy.Before, WhitespacePolicy.After, WhitespacePolicy.Both]) {
			final out:String = writeWith('class C { static function m() { while (a) b; } }', policy);
			Assert.isTrue(out.indexOf('while (a)') != -1,
				'while kw should keep trailing space under policy $policy in: <$out>');
		}
	}

	public function testJsonOnlyBeforeMapsToBefore():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"whitespace": {"ifPolicy": "onlyBefore"}}');
		Assert.equals(WhitespacePolicy.Before, opts.ifPolicy);
	}

	public function testJsonNoneMapsToNone():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"whitespace": {"ifPolicy": "none"}}');
		Assert.equals(WhitespacePolicy.None, opts.ifPolicy);
	}

	public function testJsonAroundMapsToBoth():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"whitespace": {"ifPolicy": "around"}}');
		Assert.equals(WhitespacePolicy.Both, opts.ifPolicy);
	}

	private inline function writeWith(src:String, ifPolicy:WhitespacePolicy):String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), makeOpts(ifPolicy));
	}

	private inline function makeOpts(ifPolicy:WhitespacePolicy):HxModuleWriteOptions {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.ifPolicy = ifPolicy;
		return opts;
	}
}

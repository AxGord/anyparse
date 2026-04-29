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
 * ω-try-policy — runtime-switchable `tryPolicy` whitespace policy for
 * the gap between the `try` keyword and its body. Consumed by
 * `HxStatement.TryCatchStmt` only (block-body form) via
 * `@:fmt(tryPolicy)` on the ctor. `WhitespacePolicy.After` (default)
 * emits `try {`; `Before` / `None` (mapped from JSON `"onlyBefore"` /
 * `"none"`) collapse the gap to `try{`. The bare-body sibling
 * `HxStatement.TryCatchStmtBare` does NOT carry the flag — its first
 * field's `@:fmt(bareBodyBreaks)` triggers the
 * `stripKwTrailingSpace` predicate in `WriterLowering.lowerEnumBranch`,
 * which gates the slot to `null` regardless of policy.
 *
 * The knob is wired via `WriterLowering.kwTrailingSpacePolicy` —
 * mirror of `openDelimPolicySpace` for the kw side, shared with
 * `ifPolicy` / `forPolicy` / `whilePolicy` / `switchPolicy`.
 */
@:nullSafety(Strict)
class HxTryPolicyOptionsTest extends Test {

	public function new():Void {
		super();
	}

	public function testTryPolicyDefaultIsAfter():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(WhitespacePolicy.After, defaults.tryPolicy);
	}

	public function testTryStmtAfterEmitsSpaceBeforeBrace():Void {
		final out:String = writeWith('class C { static function m() { try { a; } catch (e:Any) {} } }', WhitespacePolicy.After);
		Assert.isTrue(out.indexOf('try {') != -1, 'expected `try {` in: <$out>');
	}

	public function testTryStmtNoneCollapsesGap():Void {
		final out:String = writeWith('class C { static function m() { try { a; } catch (e:Any) {} } }', WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('try{') != -1, 'expected `try{` in: <$out>');
		Assert.isTrue(out.indexOf('try {') == -1, 'did not expect `try {` in: <$out>');
	}

	public function testTryStmtBeforeCollapsesGap():Void {
		final out:String = writeWith('class C { static function m() { try { a; } catch (e:Any) {} } }', WhitespacePolicy.Before);
		Assert.isTrue(out.indexOf('try{') != -1, 'expected `try{` in: <$out>');
	}

	public function testTryStmtBothMatchesAfter():Void {
		final out:String = writeWith('class C { static function m() { try { a; } catch (e:Any) {} } }', WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('try {') != -1, 'expected `try {` in: <$out>');
	}

	public function testCatchKwUnaffectedByTryPolicy():Void {
		// `catch` kw is on the field-level `HxCatchClause.name`, not the
		// enum branch — kwTrailingSpacePolicy doesn't reach it.
		for (policy in [WhitespacePolicy.None, WhitespacePolicy.Before, WhitespacePolicy.After, WhitespacePolicy.Both]) {
			final out:String = writeWith('class C { static function m() { try { a; } catch (e:Any) {} } }', policy);
			Assert.isTrue(out.indexOf('catch (e') != -1,
				'catch kw should keep its layout under policy $policy in: <$out>');
		}
	}

	public function testIfKwUnaffectedByTryPolicy():Void {
		for (policy in [WhitespacePolicy.None, WhitespacePolicy.Before, WhitespacePolicy.After, WhitespacePolicy.Both]) {
			final out:String = writeWith('class C { static function m() { if (a) b; } }', policy);
			Assert.isTrue(out.indexOf('if (a)') != -1,
				'if kw should keep its trailing space under tryPolicy $policy in: <$out>');
		}
	}

	public function testForKwUnaffectedByTryPolicy():Void {
		for (policy in [WhitespacePolicy.None, WhitespacePolicy.Before, WhitespacePolicy.After, WhitespacePolicy.Both]) {
			final out:String = writeWith('class C { static function m() { for (i in 0...10) trace(i); } }', policy);
			Assert.isTrue(out.indexOf('for (i in') != -1,
				'for kw should keep trailing space under tryPolicy $policy in: <$out>');
		}
	}

	public function testJsonOnlyBeforeMapsToBefore():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"whitespace": {"tryPolicy": "onlyBefore"}}');
		Assert.equals(WhitespacePolicy.Before, opts.tryPolicy);
	}

	public function testJsonNoneMapsToNone():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"whitespace": {"tryPolicy": "none"}}');
		Assert.equals(WhitespacePolicy.None, opts.tryPolicy);
	}

	public function testJsonAroundMapsToBoth():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"whitespace": {"tryPolicy": "around"}}');
		Assert.equals(WhitespacePolicy.Both, opts.tryPolicy);
	}

	private inline function writeWith(src:String, tryPolicy:WhitespacePolicy):String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), makeOpts(tryPolicy));
	}

	private inline function makeOpts(tryPolicy:WhitespacePolicy):HxModuleWriteOptions {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.tryPolicy = tryPolicy;
		return opts;
	}
}

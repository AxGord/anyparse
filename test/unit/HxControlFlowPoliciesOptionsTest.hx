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
 * ω-control-flow-policies — runtime-switchable `forPolicy` /
 * `whilePolicy` / `switchPolicy` whitespace knobs for the gap between
 * the matching control-flow keyword and the opening `(` of its head
 * (or the bare subject for `switch`). Same shape and plumbing as
 * `ifPolicy` (slice ω-if-policy), driven through
 * `WriterLowering.kwTrailingSpacePolicy` with the candidate-flag list
 * extended to recognise the new knob names. Each ctor in
 * `HxStatement` and `HxExpr` carries the matching `@:fmt(<knob>)` so
 * the same config knob applies to both statement- and expression-form
 * usages.
 *
 * Tests assert the substring pattern that distinguishes each policy,
 * tolerant of unrelated layout so the assertions stay robust against
 * future layout tweaks. JSON round-trip covers the same enum collapse
 * (`"after"` / `"onlyBefore"` / `"none"` / `"around"`) the loader
 * already exposes for `ifPolicy`.
 */
@:nullSafety(Strict)
class HxControlFlowPoliciesOptionsTest extends Test {

	public function new():Void {
		super();
	}

	public function testDefaultsAreAfter():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(WhitespacePolicy.After, defaults.forPolicy);
		Assert.equals(WhitespacePolicy.After, defaults.whilePolicy);
		Assert.equals(WhitespacePolicy.After, defaults.switchPolicy);
	}

	public function testForStmtAfterEmitsSpace():Void {
		final out:String = writeForWith('for (i in 0...10) trace(i);', WhitespacePolicy.After);
		Assert.isTrue(out.indexOf('for (i in') != -1, 'expected `for (i in` in: <$out>');
	}

	public function testForStmtNoneCollapsesGap():Void {
		final out:String = writeForWith('for (i in 0...10) trace(i);', WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('for(i in') != -1, 'expected `for(i in` in: <$out>');
		Assert.isTrue(out.indexOf('for (') == -1, 'did not expect `for (` in: <$out>');
	}

	public function testForExprNoneCollapsesGap():Void {
		final out:String = writeBodyStmt('var xs = [for (i in 0...3) i];', p -> p.forPolicy = WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('for(i in') != -1, 'expected `for(i in` in expression position: <$out>');
	}

	public function testWhileStmtNoneCollapsesGap():Void {
		final out:String = writeWhileWith('while (a) b;', WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('while(a)') != -1, 'expected `while(a)` in: <$out>');
	}

	public function testWhileStmtAfterEmitsSpace():Void {
		final out:String = writeWhileWith('while (a) b;', WhitespacePolicy.After);
		Assert.isTrue(out.indexOf('while (a)') != -1, 'expected `while (a)` in: <$out>');
	}

	public function testSwitchStmtNoneCollapsesGap():Void {
		final out:String = writeSwitchWith('switch (a) { case _: b; }', WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('switch(a)') != -1, 'expected `switch(a)` in: <$out>');
	}

	public function testSwitchStmtAfterEmitsSpace():Void {
		final out:String = writeSwitchWith('switch (a) { case _: b; }', WhitespacePolicy.After);
		Assert.isTrue(out.indexOf('switch (a)') != -1, 'expected `switch (a)` in: <$out>');
	}

	public function testSwitchExprNoneCollapsesGap():Void {
		final out:String = writeBodyStmt('var x = switch (a) { case _: 1; };', p -> p.switchPolicy = WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('switch(a)') != -1, 'expected `switch(a)` in expression position: <$out>');
	}

	public function testIfPolicyUnaffectedByControlFlowKnobs():Void {
		// `if` ctor carries `@:fmt(ifPolicy)` only — flipping forPolicy /
		// whilePolicy / switchPolicy must not collapse the if gap.
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.forPolicy = WhitespacePolicy.None;
		opts.whilePolicy = WhitespacePolicy.None;
		opts.switchPolicy = WhitespacePolicy.None;
		final out:String = HxModuleWriter.write(
			HaxeModuleParser.parse('class C { static function m() { if (a) b; } }'), opts);
		Assert.isTrue(out.indexOf('if (a)') != -1, 'if kw should keep trailing space (default ifPolicy=After) in: <$out>');
	}

	public function testJsonForPolicyOnlyBeforeMapsToBefore():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"whitespace": {"forPolicy": "onlyBefore"}}');
		Assert.equals(WhitespacePolicy.Before, opts.forPolicy);
	}

	public function testJsonWhilePolicyNoneMapsToNone():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"whitespace": {"whilePolicy": "none"}}');
		Assert.equals(WhitespacePolicy.None, opts.whilePolicy);
	}

	public function testJsonSwitchPolicyAroundMapsToBoth():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"whitespace": {"switchPolicy": "around"}}');
		Assert.equals(WhitespacePolicy.Both, opts.switchPolicy);
	}

	private inline function writeForWith(body:String, policy:WhitespacePolicy):String {
		return writeBodyStmt(body, p -> p.forPolicy = policy);
	}

	private inline function writeWhileWith(body:String, policy:WhitespacePolicy):String {
		return writeBodyStmt(body, p -> p.whilePolicy = policy);
	}

	private inline function writeSwitchWith(body:String, policy:WhitespacePolicy):String {
		return writeBodyStmt(body, p -> p.switchPolicy = policy);
	}

	private function writeBodyStmt(body:String, mutate:HxModuleWriteOptions -> Void):String {
		final src:String = 'class C { static function m() { $body } }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		mutate(opts);
		return HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
	}
}

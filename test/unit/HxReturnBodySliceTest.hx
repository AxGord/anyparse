package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.BodyPolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-return-body — `opt.returnBody:BodyPolicy` driving the separator
 * between `return` and its value expression at `HxStatement.ReturnStmt`.
 * Mirrors `ifBody` / `forBody` / `whileBody` / `doBody` shape: same
 * `bodyPolicyWrap` macro path, same 4-value `BodyPolicy` enum
 * (`Same` / `Next` / `FitLine` / `Keep`).
 *
 * Default is `FitLine` — the only `*Body` knob that does NOT default
 * to `Next`, because haxe-formatter's effective `sameLine.returnBody:
 * @:default(Same)` semantics wrap long values via a separate
 * `wrapping.maxLineLength` pass. Strict `Same` (no wrap) requires an
 * explicit `hxformat.json` override.
 *
 * The sibling JSON knob `sameLine.returnBodySingleLine` (refining the
 * policy for returns whose value is single-line) is parsed and silently
 * dropped — single-line refinement is a separate axis not yet wired
 * through the runtime. Verified via a dedicated test that asserts the
 * loader does not error on the key.
 */
@:nullSafety(Strict)
class HxReturnBodySliceTest extends Test {

	public function new():Void {
		super();
	}

	public function testDefaultIsFitLine():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(BodyPolicy.FitLine, defaults.returnBody);
	}

	public function testSameKeepsValueFlat():Void {
		final out:String = writeWith('class M { function f():Int { return 1; } }', BodyPolicy.Same);
		Assert.isTrue(out.indexOf('return 1;') != -1, 'expected `return 1;` flat in: <$out>');
	}

	public function testNextBreaksShortValue():Void {
		final out:String = writeWith('class M { function f():Int { return 1; } }', BodyPolicy.Next);
		Assert.isTrue(out.indexOf('return\n') != -1, 'expected hardline after `return` in: <$out>');
		Assert.isTrue(out.indexOf('return 1;') == -1, 'did not expect `return 1;` flat in: <$out>');
	}

	public function testFitLineFitsShortValueFlat():Void {
		final out:String = writeWith('class M { function f():Int { return 1; } }', BodyPolicy.FitLine);
		Assert.isTrue(out.indexOf('return 1;') != -1, 'expected `return 1;` flat (fits lineWidth) in: <$out>');
	}

	public function testFitLineBreaksLongValue():Void {
		final buf:StringBuf = new StringBuf();
		for (i in 0...200) buf.add('-');
		final longLit:String = '"' + buf.toString() + '"';
		final src:String = 'class M { function f():String { return $longLit; } }';
		final out:String = writeWith(src, BodyPolicy.FitLine);
		Assert.isTrue(out.indexOf('return\n') != -1, 'expected break before long value (>lineWidth) in: <$out>');
	}

	public function testKeepDoesNotForceLayout():Void {
		final out:String = writeWith('class M { function f():Int { return 1; } }', BodyPolicy.Keep);
		Assert.isTrue(out.indexOf('return') != -1, 'sanity: `return` present in: <$out>');
	}

	public function testVoidReturnUnaffected():Void {
		final out:String = writeWith('class M { function f():Void { return; } }', BodyPolicy.Next);
		Assert.isTrue(out.indexOf('return;') != -1, 'void `return;` must stay flat regardless of policy in: <$out>');
		Assert.isTrue(out.indexOf('return\n') == -1, 'void `return;` must not break in: <$out>');
	}

	public function testConfigLoaderMapsReturnBodySame():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine": {"returnBody": "same"}}'
		);
		Assert.equals(BodyPolicy.Same, opts.returnBody);
	}

	public function testConfigLoaderMapsReturnBodyNext():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine": {"returnBody": "next"}}'
		);
		Assert.equals(BodyPolicy.Next, opts.returnBody);
	}

	public function testConfigLoaderMapsReturnBodyKeep():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine": {"returnBody": "keep"}}'
		);
		Assert.equals(BodyPolicy.Keep, opts.returnBody);
	}

	public function testConfigLoaderMapsReturnBodyFitLine():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine": {"returnBody": "fitLine"}}'
		);
		Assert.equals(BodyPolicy.FitLine, opts.returnBody);
	}

	public function testConfigLoaderMissingKeyKeepsDefault():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(BodyPolicy.FitLine, opts.returnBody);
	}

	public function testConfigLoaderTolerateReturnBodySingleLine():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine": {"returnBody": "next", "returnBodySingleLine": "same"}}'
		);
		Assert.equals(BodyPolicy.Next, opts.returnBody);
	}

	private inline function writeWith(src:String, policy:BodyPolicy):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.returnBody = policy;
		return HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
	}
}

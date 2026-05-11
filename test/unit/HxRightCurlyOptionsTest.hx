package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.RightCurlyPlacement;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-blockright-curly — `blockRightCurly:RightCurlyPlacement` knob
 * gating the hardline before `}` for plain block bodies
 * (`HxStatement.BlockStmt`, `HxExpr.BlockExpr`, `HxSwitchStmt.cases`,
 * `HxSwitchStmtBare.cases`). Default `Same` keeps the standard
 * close-on-own-line layout; `Inline` drops the before-close hardline
 * so the brace glues to the last body token. Drives
 * haxe-formatter's `lineEnds.rightCurly: before|both|after|none`
 * (collapsed to 2 values — see `HxFormatRightCurlyPolicy`).
 */
@:nullSafety(Strict)
class HxRightCurlyOptionsTest extends Test {

	public function new():Void {
		super();
	}

	public function testDefaultMatchesUpstream():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(RightCurlyPlacement.Same, defaults.blockRightCurly);
	}

	public function testConfigLoaderMapsBeforeToSame():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"rightCurly": "before"}}');
		Assert.equals(RightCurlyPlacement.Same, opts.blockRightCurly);
	}

	public function testConfigLoaderMapsBothToSame():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"rightCurly": "both"}}');
		Assert.equals(RightCurlyPlacement.Same, opts.blockRightCurly);
	}

	public function testConfigLoaderMapsAfterToInline():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"rightCurly": "after"}}');
		Assert.equals(RightCurlyPlacement.Inline, opts.blockRightCurly);
	}

	public function testConfigLoaderMapsNoneToInline():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"rightCurly": "none"}}');
		Assert.equals(RightCurlyPlacement.Inline, opts.blockRightCurly);
	}

	public function testConfigLoaderMissingKeepsDefault():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(RightCurlyPlacement.Same, opts.blockRightCurly);
	}

	public function testBlockCurlySubKeyOverridesGlobalForBlockRightCurly():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"lineEnds": {"rightCurly": "after", "blockCurly": {"rightCurly": "before"}}}'
		);
		Assert.equals(RightCurlyPlacement.Same, opts.blockRightCurly);
	}

	public function testBlockCurlySubKeyAloneSetsBlockRightCurly():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"lineEnds": {"blockCurly": {"rightCurly": "after"}}}'
		);
		Assert.equals(RightCurlyPlacement.Inline, opts.blockRightCurly);
	}

	public function testSameKeepsBlockStmtCloseOnOwnLine():Void {
		final src:String = 'class Main {\n\tstatic function f() {\n\t\tif (true) {\n\t\t\ttrace(1);\n\t\t}\n\t}\n}';
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), makeOpts(RightCurlyPlacement.Same));
		Assert.isTrue(out.indexOf('trace(1);\n\t\t}') != -1, 'expected close on own line in: <$out>');
	}

	public function testInlineGluesBlockStmtClose():Void {
		final src:String = 'class Main {\n\tstatic function f() {\n\t\tif (true) {\n\t\t\ttrace(1);\n\t\t}\n\t}\n}';
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), makeOpts(RightCurlyPlacement.Inline));
		// With Inline, the close `}` for the inner `if` block glues to
		// the last body token: `trace(1);}` (no hardline before).
		Assert.isTrue(out.indexOf('trace(1);}') != -1, 'expected close glued in: <$out>');
	}

	private inline function makeOpts(rc:RightCurlyPlacement):HxModuleWriteOptions {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		// Mirror the loader's `lineEnds.rightCurly` cascade — currently
		// the only per-construct RightCurlyPlacement knob is
		// `blockRightCurly`. Add siblings here as their emit sites
		// convert from bare-flag to knob-form.
		opts.blockRightCurly = rc;
		return opts;
	}
}

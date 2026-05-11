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
 * ω-blockright-curly + ω-anonfunction-right-curly —
 * `blockRightCurly:RightCurlyPlacement` knob for plain block bodies
 * (`HxStatement.BlockStmt`, `HxExpr.BlockExpr`, `HxSwitchStmt.cases`,
 * `HxSwitchStmtBare.cases`); `anonFunctionRightCurly` knob for
 * anonymous function expression bodies (`HxFnExpr.body` through
 * `HxFnBlock.stmts`, gated on `_inAnonFnBody` so `HxFnDecl.body`
 * stays on pre-slice `_dhl()`). Default `Same` for both knobs keeps
 * the standard close-on-own-line layout; `Inline` drops the
 * before-close hardline so the brace glues to the last body token.
 * Drives haxe-formatter's `lineEnds.rightCurly: before|both|after|none`
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
		Assert.equals(RightCurlyPlacement.Same, defaults.anonFunctionRightCurly);
	}

	public function testConfigLoaderMapsBeforeToSame():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"rightCurly": "before"}}');
		Assert.equals(RightCurlyPlacement.Same, opts.blockRightCurly);
		Assert.equals(RightCurlyPlacement.Same, opts.anonFunctionRightCurly);
	}

	public function testConfigLoaderMapsBothToSame():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"rightCurly": "both"}}');
		Assert.equals(RightCurlyPlacement.Same, opts.blockRightCurly);
		Assert.equals(RightCurlyPlacement.Same, opts.anonFunctionRightCurly);
	}

	public function testConfigLoaderMapsAfterToInline():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"rightCurly": "after"}}');
		Assert.equals(RightCurlyPlacement.Inline, opts.blockRightCurly);
		Assert.equals(RightCurlyPlacement.Inline, opts.anonFunctionRightCurly);
	}

	public function testConfigLoaderMapsNoneToInline():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"rightCurly": "none"}}');
		Assert.equals(RightCurlyPlacement.Inline, opts.blockRightCurly);
		Assert.equals(RightCurlyPlacement.Inline, opts.anonFunctionRightCurly);
	}

	public function testConfigLoaderMissingKeepsDefault():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(RightCurlyPlacement.Same, opts.blockRightCurly);
		Assert.equals(RightCurlyPlacement.Same, opts.anonFunctionRightCurly);
	}

	public function testBlockCurlySubKeyOverridesGlobalForBlockRightCurly():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"lineEnds": {"rightCurly": "after", "blockCurly": {"rightCurly": "before"}}}'
		);
		Assert.equals(RightCurlyPlacement.Same, opts.blockRightCurly);
		// Sibling cascade unaffected by blockCurly sub-key.
		Assert.equals(RightCurlyPlacement.Inline, opts.anonFunctionRightCurly);
	}

	public function testBlockCurlySubKeyAloneSetsBlockRightCurly():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"lineEnds": {"blockCurly": {"rightCurly": "after"}}}'
		);
		Assert.equals(RightCurlyPlacement.Inline, opts.blockRightCurly);
		// Sub-key targets blockCurly only; anonFunction keeps default.
		Assert.equals(RightCurlyPlacement.Same, opts.anonFunctionRightCurly);
	}

	public function testAnonFunctionCurlySubKeyOverridesGlobalForAnonFunctionRightCurly():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"lineEnds": {"rightCurly": "after", "anonFunctionCurly": {"rightCurly": "before"}}}'
		);
		Assert.equals(RightCurlyPlacement.Same, opts.anonFunctionRightCurly);
		// Sibling cascade unaffected by anonFunctionCurly sub-key.
		Assert.equals(RightCurlyPlacement.Inline, opts.blockRightCurly);
	}

	public function testAnonFunctionCurlySubKeyAloneSetsAnonFunctionRightCurly():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"lineEnds": {"anonFunctionCurly": {"rightCurly": "after"}}}'
		);
		Assert.equals(RightCurlyPlacement.Inline, opts.anonFunctionRightCurly);
		// Sub-key targets anonFunctionCurly only; block keeps default.
		Assert.equals(RightCurlyPlacement.Same, opts.blockRightCurly);
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

	public function testSameKeepsAnonFnExprCloseOnOwnLine():Void {
		final src:String = 'class Main {\n\tstatic function f() {\n\t\tvar g = function() {\n\t\t\ttrace(1);\n\t\t};\n\t}\n}';
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), makeOpts(RightCurlyPlacement.Same));
		// Anon-fn body close stays on its own line in `Same`.
		Assert.isTrue(out.indexOf('trace(1);\n\t\t}') != -1, 'expected anon-fn close on own line in: <$out>');
	}

	public function testInlineGluesAnonFnExprClose():Void {
		final src:String = 'class Main {\n\tstatic function f() {\n\t\tvar g = function() {\n\t\t\ttrace(1);\n\t\t};\n\t}\n}';
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), makeOpts(RightCurlyPlacement.Inline));
		// With Inline + `_inAnonFnBody=true`, the close `}` glues to the
		// last anon-fn body token: `trace(1);}` (no hardline before).
		Assert.isTrue(out.indexOf('trace(1);}') != -1, 'expected anon-fn close glued in: <$out>');
	}

	public function testFnDeclBodyUnaffectedByAnonFunctionRightCurly():Void {
		// `HxFnDecl.body` shares the same `HxFnBlock` Star but
		// `_inAnonFnBody=false`, so `anonFunctionRightCurly=Inline` must
		// NOT glue the function-decl close brace.
		final src:String = 'class Main {\n\tstatic function f() {\n\t\ttrace(1);\n\t}\n}';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.anonFunctionRightCurly = RightCurlyPlacement.Inline;
		// Leave blockRightCurly at default Same so BlockStmt close isn't glued either.
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('trace(1);\n\t}') != -1, 'expected fn-decl close on own line in: <$out>');
	}

	private inline function makeOpts(rc:RightCurlyPlacement):HxModuleWriteOptions {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		// Mirror the loader's `lineEnds.rightCurly` cascade — set every
		// per-construct RightCurlyPlacement knob in lockstep so byte-shape
		// tests can exercise either the block or anon-fn path with one
		// helper call.
		opts.blockRightCurly = rc;
		opts.anonFunctionRightCurly = rc;
		return opts;
	}
}

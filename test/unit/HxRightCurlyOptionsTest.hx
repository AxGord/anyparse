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
 * ω-blockright-curly + ω-anonfunction-right-curly + ω-anontype-right-curly
 * + ω-objectlit-right-curly — per-construct `RightCurlyPlacement` knobs:
 *  - `blockRightCurly` for plain block bodies (`HxStatement.BlockStmt`,
 *    `HxExpr.BlockExpr`, `HxSwitchStmt.cases`, `HxSwitchStmtBare.cases`);
 *  - `anonFunctionRightCurly` for anonymous function expression bodies
 *    (`HxFnExpr.body` through `HxFnBlock.stmts`, gated on `_inAnonFnBody`
 *    so `HxFnDecl.body` stays on pre-slice `_dhl()`);
 *  - `anonTypeRightCurly` for anonymous type braces (`HxType.Anon`);
 *  - `objectLiteralRightCurly` for anonymous object literal braces
 *    (`HxObjectLit.fields`).
 * Default `Same` for all four knobs keeps the standard close-on-own-line
 * layout; `Inline` drops the before-close hardline so the brace glues to
 * the last body token. Drives haxe-formatter's
 * `lineEnds.rightCurly: before|both|after|none` (collapsed to 2 values —
 * see `HxFormatRightCurlyPolicy`).
 */
@:nullSafety(Strict)
class HxRightCurlyOptionsTest extends Test {

	public function new(): Void {
		super();
	}

	public function testDefaultMatchesUpstream(): Void {
		final defaults: HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(RightCurlyPlacement.Same, defaults.blockRightCurly);
		Assert.equals(RightCurlyPlacement.Same, defaults.anonFunctionRightCurly);
		Assert.equals(RightCurlyPlacement.Same, defaults.anonTypeRightCurly);
		Assert.equals(RightCurlyPlacement.Same, defaults.objectLiteralRightCurly);
	}

	public function testConfigLoaderMapsBeforeToSame(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"rightCurly": "before"}}');
		Assert.equals(RightCurlyPlacement.Same, opts.blockRightCurly);
		Assert.equals(RightCurlyPlacement.Same, opts.anonFunctionRightCurly);
		Assert.equals(RightCurlyPlacement.Same, opts.anonTypeRightCurly);
		Assert.equals(RightCurlyPlacement.Same, opts.objectLiteralRightCurly);
	}

	public function testConfigLoaderMapsBothToSame(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"rightCurly": "both"}}');
		Assert.equals(RightCurlyPlacement.Same, opts.blockRightCurly);
		Assert.equals(RightCurlyPlacement.Same, opts.anonFunctionRightCurly);
		Assert.equals(RightCurlyPlacement.Same, opts.anonTypeRightCurly);
		Assert.equals(RightCurlyPlacement.Same, opts.objectLiteralRightCurly);
	}

	public function testConfigLoaderMapsAfterToInline(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"rightCurly": "after"}}');
		Assert.equals(RightCurlyPlacement.Inline, opts.blockRightCurly);
		Assert.equals(RightCurlyPlacement.Inline, opts.anonFunctionRightCurly);
		Assert.equals(RightCurlyPlacement.Inline, opts.anonTypeRightCurly);
		Assert.equals(RightCurlyPlacement.Inline, opts.objectLiteralRightCurly);
	}

	public function testConfigLoaderMapsNoneToInline(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"rightCurly": "none"}}');
		Assert.equals(RightCurlyPlacement.Inline, opts.blockRightCurly);
		Assert.equals(RightCurlyPlacement.Inline, opts.anonFunctionRightCurly);
		Assert.equals(RightCurlyPlacement.Inline, opts.anonTypeRightCurly);
		Assert.equals(RightCurlyPlacement.Inline, opts.objectLiteralRightCurly);
	}

	public function testConfigLoaderMissingKeepsDefault(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(RightCurlyPlacement.Same, opts.blockRightCurly);
		Assert.equals(RightCurlyPlacement.Same, opts.anonFunctionRightCurly);
		Assert.equals(RightCurlyPlacement.Same, opts.anonTypeRightCurly);
		Assert.equals(RightCurlyPlacement.Same, opts.objectLiteralRightCurly);
	}

	public function testBlockCurlySubKeyOverridesGlobalForBlockRightCurly(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"lineEnds": {"rightCurly": "after", "blockCurly": {"rightCurly": "before"}}}'
		);
		Assert.equals(RightCurlyPlacement.Same, opts.blockRightCurly);
		// Sibling cascades unaffected by blockCurly sub-key.
		Assert.equals(RightCurlyPlacement.Inline, opts.anonFunctionRightCurly);
		Assert.equals(RightCurlyPlacement.Inline, opts.anonTypeRightCurly);
		Assert.equals(RightCurlyPlacement.Inline, opts.objectLiteralRightCurly);
	}

	public function testBlockCurlySubKeyAloneSetsBlockRightCurly(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"blockCurly": {"rightCurly": "after"}}}');
		Assert.equals(RightCurlyPlacement.Inline, opts.blockRightCurly);
		// Sub-key targets blockCurly only; siblings keep default.
		Assert.equals(RightCurlyPlacement.Same, opts.anonFunctionRightCurly);
		Assert.equals(RightCurlyPlacement.Same, opts.anonTypeRightCurly);
		Assert.equals(RightCurlyPlacement.Same, opts.objectLiteralRightCurly);
	}

	public function testAnonFunctionCurlySubKeyOverridesGlobalForAnonFunctionRightCurly(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"lineEnds": {"rightCurly": "after", "anonFunctionCurly": {"rightCurly": "before"}}}'
		);
		Assert.equals(RightCurlyPlacement.Same, opts.anonFunctionRightCurly);
		// Sibling cascades unaffected by anonFunctionCurly sub-key.
		Assert.equals(RightCurlyPlacement.Inline, opts.blockRightCurly);
		Assert.equals(RightCurlyPlacement.Inline, opts.anonTypeRightCurly);
		Assert.equals(RightCurlyPlacement.Inline, opts.objectLiteralRightCurly);
	}

	public function testAnonFunctionCurlySubKeyAloneSetsAnonFunctionRightCurly(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"lineEnds": {"anonFunctionCurly": {"rightCurly": "after"}}}'
		);
		Assert.equals(RightCurlyPlacement.Inline, opts.anonFunctionRightCurly);
		// Sub-key targets anonFunctionCurly only; siblings keep default.
		Assert.equals(RightCurlyPlacement.Same, opts.blockRightCurly);
		Assert.equals(RightCurlyPlacement.Same, opts.anonTypeRightCurly);
		Assert.equals(RightCurlyPlacement.Same, opts.objectLiteralRightCurly);
	}

	public function testAnonTypeCurlySubKeyOverridesGlobalForAnonTypeRightCurly(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"lineEnds": {"rightCurly": "after", "anonTypeCurly": {"rightCurly": "before"}}}'
		);
		Assert.equals(RightCurlyPlacement.Same, opts.anonTypeRightCurly);
		// Sibling cascades unaffected by anonTypeCurly sub-key.
		Assert.equals(RightCurlyPlacement.Inline, opts.blockRightCurly);
		Assert.equals(RightCurlyPlacement.Inline, opts.anonFunctionRightCurly);
		Assert.equals(RightCurlyPlacement.Inline, opts.objectLiteralRightCurly);
	}

	public function testAnonTypeCurlySubKeyAloneSetsAnonTypeRightCurly(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"lineEnds": {"anonTypeCurly": {"rightCurly": "after"}}}'
		);
		Assert.equals(RightCurlyPlacement.Inline, opts.anonTypeRightCurly);
		// Sub-key targets anonTypeCurly only; siblings keep default.
		Assert.equals(RightCurlyPlacement.Same, opts.blockRightCurly);
		Assert.equals(RightCurlyPlacement.Same, opts.anonFunctionRightCurly);
		Assert.equals(RightCurlyPlacement.Same, opts.objectLiteralRightCurly);
	}

	public function testObjectLiteralCurlySubKeyOverridesGlobalForObjectLiteralRightCurly(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"lineEnds": {"rightCurly": "after", "objectLiteralCurly": {"rightCurly": "before"}}}'
		);
		Assert.equals(RightCurlyPlacement.Same, opts.objectLiteralRightCurly);
		// Sibling cascades unaffected by objectLiteralCurly sub-key.
		Assert.equals(RightCurlyPlacement.Inline, opts.blockRightCurly);
		Assert.equals(RightCurlyPlacement.Inline, opts.anonFunctionRightCurly);
		Assert.equals(RightCurlyPlacement.Inline, opts.anonTypeRightCurly);
	}

	public function testObjectLiteralCurlySubKeyAloneSetsObjectLiteralRightCurly(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"lineEnds": {"objectLiteralCurly": {"rightCurly": "after"}}}'
		);
		Assert.equals(RightCurlyPlacement.Inline, opts.objectLiteralRightCurly);
		// Sub-key targets objectLiteralCurly only; siblings keep default.
		Assert.equals(RightCurlyPlacement.Same, opts.blockRightCurly);
		Assert.equals(RightCurlyPlacement.Same, opts.anonFunctionRightCurly);
		Assert.equals(RightCurlyPlacement.Same, opts.anonTypeRightCurly);
	}

	public function testSameKeepsBlockStmtCloseOnOwnLine(): Void {
		final src: String = 'class Main {\n\tstatic function f() {\n\t\tif (true) {\n\t\t\ttrace(1);\n\t\t}\n\t}\n}';
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), makeOpts(RightCurlyPlacement.Same));
		Assert.isTrue(out.indexOf('trace(1);\n\t\t}') != -1, 'expected close on own line in: <$out>');
	}

	public function testInlineGluesBlockStmtClose(): Void {
		final src: String = 'class Main {\n\tstatic function f() {\n\t\tif (true) {\n\t\t\ttrace(1);\n\t\t}\n\t}\n}';
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), makeOpts(RightCurlyPlacement.Inline));
		// With Inline, the close `}` for the inner `if` block glues to
		// the last body token: `trace(1);}` (no hardline before).
		Assert.isTrue(out.indexOf('trace(1);}') != -1, 'expected close glued in: <$out>');
	}

	public function testSameKeepsAnonFnExprCloseOnOwnLine(): Void {
		final src: String = 'class Main {\n\tstatic function f() {\n\t\tvar g = function() {\n\t\t\ttrace(1);\n\t\t};\n\t}\n}';
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), makeOpts(RightCurlyPlacement.Same));
		// Anon-fn body close stays on its own line in `Same`.
		Assert.isTrue(out.indexOf('trace(1);\n\t\t}') != -1, 'expected anon-fn close on own line in: <$out>');
	}

	public function testInlineGluesAnonFnExprClose(): Void {
		final src: String = 'class Main {\n\tstatic function f() {\n\t\tvar g = function() {\n\t\t\ttrace(1);\n\t\t};\n\t}\n}';
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), makeOpts(RightCurlyPlacement.Inline));
		// With Inline + `_inAnonFnBody=true`, the close `}` glues to the
		// last anon-fn body token: `trace(1);}` (no hardline before).
		Assert.isTrue(out.indexOf('trace(1);}') != -1, 'expected anon-fn close glued in: <$out>');
	}

	public function testFnDeclBodyUnaffectedByAnonFunctionRightCurly(): Void {
		// `HxFnDecl.body` shares the same `HxFnBlock` Star but
		// `_inAnonFnBody=false`, so `anonFunctionRightCurly=Inline` must
		// NOT glue the function-decl close brace.
		final src: String = 'class Main {\n\tstatic function f() {\n\t\ttrace(1);\n\t}\n}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.anonFunctionRightCurly = RightCurlyPlacement.Inline;
		// Leave blockRightCurly + anonTypeRightCurly at default Same so
		// neither BlockStmt close nor any other shape is glued.
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('trace(1);\n\t}') != -1, 'expected fn-decl close on own line in: <$out>');
	}

	public function testSameKeepsAnonTypeCloseOnOwnLine(): Void {
		// Multi-line anon-type (newlines between fields trigger trivia
		// branch in `triviaSepStarExpr`). With `Same`, the close `}`
		// stays on its own line.
		final src: String = 'typedef Point = {\n\tx:Int,\n\ty:Int\n}';
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), makeOpts(RightCurlyPlacement.Same));
		Assert.isTrue(out.indexOf('y:Int\n}') != -1, 'expected anon-type close on own line in: <$out>');
	}

	public function testInlineGluesAnonTypeClose(): Void {
		// With `Inline`, the close `}` glues to the last field token.
		final src: String = 'typedef Point = {\n\tx:Int,\n\ty:Int\n}';
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), makeOpts(RightCurlyPlacement.Inline));
		Assert.isTrue(out.indexOf('y:Int}') != -1, 'expected anon-type close glued in: <$out>');
	}

	public function testAnonTypeUnaffectedWhenOnlyBlockKnobInline(): Void {
		// `anonTypeRightCurly=Same`, `blockRightCurly=Inline`. The anon-
		// type close stays on its own line — the block knob does NOT
		// propagate to `HxType.Anon` (different Star, different meta).
		final src: String = 'typedef Point = {\n\tx:Int,\n\ty:Int\n}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.blockRightCurly = RightCurlyPlacement.Inline;
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('y:Int\n}') != -1, 'expected anon-type close on own line in: <$out>');
	}

	public function testSameKeepsObjectLiteralCloseOnOwnLine(): Void {
		// Multi-line object literal (newlines between fields trigger trivia
		// branch in `triviaSepStarExpr`). With `Same`, the close `}` stays
		// on its own line.
		final src: String = 'class Main {\n\tstatic function f() {\n\t\tvar o = {\n\t\t\ta: 1,\n\t\t\tb: 2\n\t\t};\n\t}\n}';
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), makeOpts(RightCurlyPlacement.Same));
		Assert.isTrue(out.indexOf('b: 2\n\t\t}') != -1, 'expected object-literal close on own line in: <$out>');
	}

	public function testInlineGluesObjectLiteralClose(): Void {
		// With `Inline`, the close `}` glues to the last field token.
		final src: String = 'class Main {\n\tstatic function f() {\n\t\tvar o = {\n\t\t\ta: 1,\n\t\t\tb: 2\n\t\t};\n\t}\n}';
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), makeOpts(RightCurlyPlacement.Inline));
		Assert.isTrue(out.indexOf('b: 2}') != -1, 'expected object-literal close glued in: <$out>');
	}

	public function testObjectLiteralUnaffectedWhenOnlyBlockKnobInline(): Void {
		// `objectLiteralRightCurly=Same`, `blockRightCurly=Inline`. The
		// object-literal close stays on its own line — the block knob does
		// NOT propagate to `HxObjectLit.fields` (different Star, different
		// meta).
		final src: String = 'class Main {\n\tstatic function f() {\n\t\tvar o = {\n\t\t\ta: 1,\n\t\t\tb: 2\n\t\t};\n\t}\n}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.blockRightCurly = RightCurlyPlacement.Inline;
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('b: 2\n\t\t}') != -1, 'expected object-literal close on own line in: <$out>');
	}

	/**
	 * ω-wraplist-trailbreakdoc — wrap-engine path parity with the trivia
	 * branch. Flat source (no newlines between fields) and 4 fields force
	 * the `noTriviaBranch` of `triviaSepStarExpr` through `WrapList.emit`,
	 * whose default `objectLiteralWrap` cascade commits to `OnePerLine`
	 * at `count >= 4`. The `trailBreak` Doc fed into
	 * `WrapList.shapeOnePerLine` then drives close placement — `Empty`
	 * (Inline) glues the close to the last field, `Line('\n')` (Same)
	 * keeps it on its own line.
	 */
	public function testSameKeepsObjectLiteralCloseOnOwnLineInWrapEngine(): Void {
		final src: String = 'class Main {\n\tstatic function f() {\n\t\tvar o = {a: 1, b: 2, c: 3, d: 4};\n\t}\n}';
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), makeOpts(RightCurlyPlacement.Same));
		Assert.isTrue(out.indexOf('d: 4\n\t\t}') != -1, 'expected wrap-engine close on own line in: <$out>');
	}

	public function testInlineGluesObjectLiteralCloseInWrapEngine(): Void {
		final src: String = 'class Main {\n\tstatic function f() {\n\t\tvar o = {a: 1, b: 2, c: 3, d: 4};\n\t}\n}';
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), makeOpts(RightCurlyPlacement.Inline));
		Assert.isTrue(out.indexOf('d: 4}') != -1, 'expected wrap-engine close glued in: <$out>');
	}

	public function testNoWrapShapeUnaffectedByObjectLiteralRightCurly(): Void {
		// 2 fields, flat source — cascade picks `NoWrap` (count <= 3 and
		// total < 60 cols). `shapeNoWrap` emits the single-line
		// `{a: 1, b: 2}` shape with no trailBreak in play, so the close
		// is glued regardless of `objectLiteralRightCurly`.
		final src: String = 'class Main {\n\tstatic function f() {\n\t\tvar o = {a: 1, b: 2};\n\t}\n}';
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), makeOpts(RightCurlyPlacement.Inline));
		Assert.isTrue(out.indexOf('{a: 1, b: 2}') != -1, 'expected single-line nowrap shape in: <$out>');
	}

	private inline function makeOpts(rc: RightCurlyPlacement): HxModuleWriteOptions {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		// Mirror the loader's `lineEnds.rightCurly` cascade — set every
		// per-construct RightCurlyPlacement knob in lockstep so byte-shape
		// tests can exercise the block, anon-fn, anon-type, or object-
		// literal path with one helper call.
		opts.blockRightCurly = rc;
		opts.anonFunctionRightCurly = rc;
		opts.anonTypeRightCurly = rc;
		opts.objectLiteralRightCurly = rc;
		return opts;
	}

}

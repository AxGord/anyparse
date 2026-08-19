package unit;

import utest.Assert;
import utest.Test;

/**
 * omega-paren-value-if-open: an expression paren whose inner is a value-position
 * `if` / `else if` chain OWNS AN INDENT LEVEL once the line overflows — break
 * after `(`, the ladder nested one level, close `)` on its own line — instead of
 * hard-flattening the ladder onto the `(` line and laying its `else` at the
 * ENCLOSING STATEMENT's indent.
 *
 * Sibling of the ternary arm (`HxParenTernaryOpenWrapSliceTest`) and gated the
 * same way: only a fillLine-family `wrapping.expressionWrapping` opens the paren,
 * so a fork-default config stays byte-identical. A chain that FITS keeps its
 * glue on both sides. Identifiers are fully synthetic and bear no relation to any
 * downstream code.
 */
@:nullSafety(Strict)
final class HxParenValueIfOpenWrapSliceTest extends Test {

	private static final BASE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140'
		+ ', "expressionWrapping": {"defaultWrap": "fillLineWithLeadingBreak"'
		+ ', "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}';
	private static final CFG: String = '$BASE, "sameLine": {"expressionIf": "next", "expressionIfFit": true}}';
	private static final NO_EXPR_WRAP: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}'
		+ ', "sameLine": {"expressionIf": "next", "expressionIfFit": true}}';

	private static final LADDER: String = 'if (!bucket) MeasureMap.PANEL_ROW_GRID_MARKICON_BOTTOM_PAD'
		+ ' else if (sharedBucket) MeasureMap.PANEL_ROW_GRID_MARKICON_SHARED_BUCKET_BOT_PAD'
		+ ' else MeasureMap.PANEL_ROW_GRID_MARKICON_BUCKET_BOTTOM_PAD';
	private static final OPEN_LADDER_3: String = '\t\t\tif (!bucket)\n\t\t\t\tMeasureMap.PANEL_ROW_GRID_MARKICON_BOTTOM_PAD\n'
		+ '\t\t\telse if (sharedBucket)\n\t\t\t\tMeasureMap.PANEL_ROW_GRID_MARKICON_SHARED_BUCKET_BOT_PAD\n'
		+ '\t\t\telse\n\t\t\t\tMeasureMap.PANEL_ROW_GRID_MARKICON_BUCKET_BOTTOM_PAD\n';

	public function new(): Void {
		super();
	}

	/**
	 * The anchor shape: an over-wide value-`if` in an expression paren at the tail of an
	 * opAddSub chain opens the paren and indents the ladder inside it. Source is written
	 * FLAT, so the answer is width-driven, not a reproduction of a source newline.
	 */
	public function testOverWideParenValueIfOpens(): Void {
		final src: String = 'class Sample {\n\tfunction run() {\n'
			+ '\t\tmarkerSprite.y = MeasureMap.PANEL_ROW_GRID_ITEM_HEIGHT - image.height - ($LADDER);\n' + '\t}\n}';
		final out: String = 'class Sample {\n\tfunction run() {\n'
			+ '\t\tmarkerSprite.y = MeasureMap.PANEL_ROW_GRID_ITEM_HEIGHT - image.height - (\n' + OPEN_LADDER_3 + '\t\t);\n' + '\t}\n}';
		Assert.equals(out, triviaWrite(src, CFG));
	}

	/** The same shape with NO arithmetic around it — the paren alone is what owns the indent level. */
	public function testOverWideParenValueIfOpensWithoutChain(): Void {
		final src: String = 'class Sample {\n\tfunction run() {\n' + '\t\tmarkerSpriteBucketHolder.yPositionValue = ($LADDER);\n' + '\t}\n}';
		final out: String = 'class Sample {\n\tfunction run() {\n' + '\t\tmarkerSpriteBucketHolder.yPositionValue = (\n' + OPEN_LADDER_3
			+ '\t\t);\n' + '\t}\n}';
		Assert.equals(out, triviaWrite(src, CFG));
	}

	/** Idempotent: the opened shape re-formats to itself byte-for-byte. */
	public function testOpenedParenValueIfIsIdempotent(): Void {
		final out: String = 'class Sample {\n\tfunction run() {\n'
			+ '\t\tmarkerSprite.y = MeasureMap.PANEL_ROW_GRID_ITEM_HEIGHT - image.height - (\n' + OPEN_LADDER_3 + '\t\t);\n' + '\t}\n}';
		Assert.equals(out, triviaWrite(out, CFG));
	}

	/** A value-`if` that FITS on its line keeps the paren glued on both sides. */
	public function testFittingParenValueIfStaysGlued(): Void {
		final src: String = 'class Sample {\n\tfunction run() {\n\t\tmarkerSprite.y = (if (bucket) 1 else 2);\n\t}\n}';
		Assert.equals(src, triviaWrite(src, CFG));
	}

	/**
	 * Config gate: without a fillLine-family `expressionWrapping` the paren stays
	 * hard-flattened, exactly as before the slice — fork default-config parity.
	 */
	public function testDefaultExpressionWrapKeepsParenValueIfGlued(): Void {
		final src: String = 'class Sample {\n\tfunction run() {\n' + '\t\tmarkerSpriteBucketHolder.yPositionValue = ($LADDER);\n' + '\t}\n}';
		final out: String = 'class Sample {\n\tfunction run() {\n' + '\t\tmarkerSpriteBucketHolder.yPositionValue = (if (!bucket)\n'
			+ '\t\t\tMeasureMap.PANEL_ROW_GRID_MARKICON_BOTTOM_PAD\n' + '\t\telse if (sharedBucket)\n'
			+ '\t\t\tMeasureMap.PANEL_ROW_GRID_MARKICON_SHARED_BUCKET_BOT_PAD\n' + '\t\telse\n'
			+ '\t\t\tMeasureMap.PANEL_ROW_GRID_MARKICON_BUCKET_BOTTOM_PAD);\n' + '\t}\n}';
		Assert.equals(out, triviaWrite(src, NO_EXPR_WRAP));
	}

	private inline function triviaWrite(src: String, cfg: String): String {
		return HxWriteFixture.triviaWrite(src, cfg);
	}

}

package unit;

import utest.Assert;
import utest.Test;

using StringTools;

/**
 * omega-opadd-trailing-paren-glue: an overflowing `+`/`-` chain whose LAST
 * operand is a bare paren-expr that OPENS (leading-breaks after `(` under a
 * fillLine-family expressionWrapping) keeps the chain head GLUED on the open
 * line (`a - b - (` then the inner nested, `)` on its own line) instead of
 * breaking the operator onto a continuation line. At the universal default
 * (no expressionWrapping) the paren stays content-glued (`- (inner`), the
 * natural-first-line probe never selects the glue shape, and the chain keeps
 * its operator break. Identifiers are fully synthetic.
 */
@:nullSafety(Strict)
final class HxOpAddTrailingParenGlueSliceTest extends Test {

	private static final CFG: String = '{"indentation":{"character":"tab","tabWidth":4,"trailingWhitespace":false,'
		+ '"alignInlineSwitchCaseBody":true},"emptyLines":{"maxAnywhereInFile":2,"afterBlocks":"remove",'
		+ '"afterLeftCurly":"keep","beforeRightCurly":"keep","classEmptyLines":{"beginType":1,"endType":1},'
		+ '"interfaceEmptyLines":{"beginType":1,"endType":1},"abstractEmptyLines":{"beginType":1,'
		+ '"endType":1}},"wrapping":{"functionSignature":{"defaultWrap":"fillLineWithLeadingBreak",'
		+ '"rules":[{"conditions":[{"cond":"totalItemLength <= n","value":100},{'
		+ '"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},'
		+ '{"conditions":[{"cond":"itemCount <= n","value":1}],"type":"noWrap"}]},'
		+ '"maxLineLength":140,"callParameter":{"defaultWrap":"fillLineWithLeadingBreak",'
		+ '"rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{'
		+ '"conditions":[{"cond":"itemCount <= n","value":1},{"cond":"totalItemLength <= n","value":100}],'
		+ '"type":"noWrap"}]},"opBoolChain":{"defaultWrap":"noWrap",'
		+ '"rules":[{"conditions":[{"cond":"itemCount <= n","value":3},{"cond":"exceedsMaxLineLength",'
		+ '"value":0}],"type":"noWrap"},{"conditions":[{"cond":"totalItemLength <= n","value":120},{'
		+ '"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{'
		+ '"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine",'
		+ '"location":"beforeLast"}]},"expressionWrapping":{"defaultWrap":"fillLineWithLeadingBreak",'
		+ '"rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]},'
		+ '"opAddSubChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"exceedsMaxLineLength",'
		+ '"value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],'
		+ '"type":"fillLine","location":"beforeLast"}]},' + '"conditionWrapping":{"defaultWrap":"fillLineWithLeadingBreak",'
		+ '"rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]}},'
		+ '"whitespace":{"addLineCommentSpace":false,"commaPolicy":"after","ifPolicy":"around",'
		+ '"forPolicy":"around","whilePolicy":"around","switchPolicy":"around","catchPolicy":"around",'
		+ '"arrowFunctionsPolicy":"around","functionTypeHaxe3Policy":"none",'
		+ '"functionTypeHaxe4Policy":"none","binopPolicy":"around","intervalPolicy":"around",'
		+ '"openingBracketPolicy":"none","closingBracketPolicy":"none",'
		+ '"bracesConfig":{"objectLiteralBraces":{"openingPolicy":"after","closingPolicy":"before"},'
		+ '"anonTypeBraces":{"openingPolicy":"after","closingPolicy":"before"},'
		+ '"typedefBraces":{"openingPolicy":"after","closingPolicy":"before"},'
		+ '"blockBraces":{"openingPolicy":"around","closingPolicy":"before"},'
		+ '"unknownBraces":{"openingPolicy":"after","closingPolicy":"before"}},'
		+ '"parenConfig":{"callParens":{"openingPolicy":"none","closingPolicy":"none"},'
		+ '"funcParamParens":{"openingPolicy":"none","closingPolicy":"none"},'
		+ '"conditionParens":{"openingPolicy":"before","closingPolicy":"after"},'
		+ '"anonFuncParamParens":{"openingPolicy":"none","closingPolicy":"none"},'
		+ '"forLoopParens":{"openingPolicy":"before","closingPolicy":"after"},'
		+ '"expressionParens":{"openingPolicy":"none","closingPolicy":"none"}}},' + '"lineEnds":{"emptyCurly":"noBreak"},'
		+ '"sameLine":{"ifBody":"fitLine","forBody":"fitLine","whileBody":"fitLine",'
		+ '"functionBody":"fitLine","expressionIf":"next","comprehensionFor":"fitLine"}}';
	private static final EXPR_WRAP_SECTION: String = '"expressionWrapping":{"defaultWrap":"fillLineWithLeadingBreak",'
		+ '"rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]},';
	private static final SRC: String = 'class Sample {\n\tfunction run() {\n'
		+ '\t\tgraphicPanel.y = Boundaries.NODE_PACK_MESH_CELL_EXTENT - photo.extent - (toggle ? linkedToggle ? '
		+ 'Boundaries.NODE_PACK_MESH_BADGEMARK_LINKED_TOGGLE_LOWEST_SPACING : Boundaries.NODE_PACK_MESH_BADGEMARK_TOGGLE_LOWEST_SPACING : '
		+ 'Boundaries.NODE_PACK_MESH_BADGEMARK_LOWEST_SPACING);\n\t}\n}';
	private static final SRC_VALUE_IF: String = 'class Sample {\n\tfunction run() {\n'
		+ '\t\tbadgeContainer.offset = baselineTextExtent + (if (packed) Boundaries.NODE_PACK_MESH_BADGEMARK_LOWEST_SPACING else if '
		+ '(linked) Boundaries.NODE_PACK_MESH_BADGEMARK_TOGGLE_LOWEST_SPACING else Boundaries.NODE_PACK_MESH_CELL_EXTENT);\n\t}\n}';

	public function new(): Void {
		super();
	}

	/** Under a fillLine-family expressionWrapping the opened trailing paren keeps the chain head glued: `a - b - (` on one line. */
	public function testFillLineGluesChainHeadToOpenedTrailingParen(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tgraphicPanel.y = Boundaries.NODE_PACK_MESH_CELL_EXTENT - photo.extent - (\n'
			+ '\t\t\ttoggle\n\t\t\t\t? linkedToggle\n\t\t\t\t\t? Boundaries.NODE_PACK_MESH_BADGEMARK_LINKED_TOGGLE_LOWEST_SPACING\n'
			+ '\t\t\t\t\t: Boundaries.NODE_PACK_MESH_BADGEMARK_TOGGLE_LOWEST_SPACING\n'
			+ '\t\t\t\t: Boundaries.NODE_PACK_MESH_BADGEMARK_LOWEST_SPACING\n\t\t);\n\t}\n\n}',
			triviaWrite(SRC, CFG)
		);
	}

	/** Without expressionWrapping (universal default) the paren stays content-glued and the chain keeps its operator break. */
	public function testDefaultConfigKeepsOperatorBreak(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tgraphicPanel.y = Boundaries.NODE_PACK_MESH_CELL_EXTENT - photo.extent\n'
			+ '\t\t\t- (toggle\n\t\t\t\t? linkedToggle\n\t\t\t\t\t? Boundaries.NODE_PACK_MESH_BADGEMARK_LINKED_TOGGLE_LOWEST_SPACING\n'
			+ '\t\t\t\t\t: Boundaries.NODE_PACK_MESH_BADGEMARK_TOGGLE_LOWEST_SPACING\n'
			+ '\t\t\t\t: Boundaries.NODE_PACK_MESH_BADGEMARK_LOWEST_SPACING);\n\t}\n\n}',
			triviaWrite(SRC, CFG.replace(EXPR_WRAP_SECTION, ''))
		);
	}

	/** A last operand that LEADS with `(` but is a Div (`(a - b) / 2`), not a bare paren-expr, must NOT glue even under the fillLine expressionWrapping: the chain breaks `beforeLast` and the operand stays flat. Guards the `endsWithCloseDelim` narrowing of the glue gate. */
	public function testParenDivLastOperandDoesNotGlue(): Void {
		final src: String = 'class Sample {\n\tfunction run() {\n'
			+ '\t\tbadgeContainer.offset = baselineTextExtent + captionTextField.measuredWidth + BADGE_SLOT_RESERVED_SIZE + ('
			+ 'Boundaries.NODE_PACK_MESH_CELL_EXTENT - iconBitmap.width) / 2;\n\t}\n}';
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tbadgeContainer.offset = baselineTextExtent + captionTextField.measuredWidth + '
			+ 'BADGE_SLOT_RESERVED_SIZE\n\t\t\t+ (Boundaries.NODE_PACK_MESH_CELL_EXTENT - iconBitmap.width) / 2;\n\t}\n\n}',
			triviaWrite(src, CFG)
		);
	}

	/**
	 * ω-opadd-hardline-paren-glue: the tail paren holds a value-`if` ladder that the
	 * `expressionIf: "next"` policy renders with FORCED breaks. That hardline used to commit the
	 * chain to its break tree before the trailing-paren glue arm could run, so the head split off
	 * onto its own line for no gain — the operand is multi-line either way. It now glues like the
	 * hardline-free ternary above, and the paren still opens under the fillLine expressionWrapping.
	 */
	public function testHardlineValueIfTailGluesChainHead(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tbadgeContainer.offset = baselineTextExtent + (\n'
			+ '\t\t\tif (packed)\n\t\t\t\tBoundaries.NODE_PACK_MESH_BADGEMARK_LOWEST_SPACING\n'
			+ '\t\t\telse if (linked)\n\t\t\t\tBoundaries.NODE_PACK_MESH_BADGEMARK_TOGGLE_LOWEST_SPACING\n'
			+ '\t\t\telse\n\t\t\t\tBoundaries.NODE_PACK_MESH_CELL_EXTENT\n\t\t);\n\t}\n\n}',
			triviaWrite(SRC_VALUE_IF, CFG)
		);
	}

	/**
	 * The glue does NOT require the paren to OPEN. Without expressionWrapping the paren stays
	 * content-glued (`+ (if (packed)`) and the ladder hard-flattens, but the chain head still keeps
	 * its two leading operands on one line: the probe glues on a head line that FITS, and only falls
	 * back to the ends-at-an-open-delimiter test when it does not. Unlike the hardline-free ternary
	 * sibling above, this arm is therefore NOT a no-expressionWrapping inertness pin.
	 */
	public function testHardlineValueIfTailGluesWithoutExpressionWrapping(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tbadgeContainer.offset = baselineTextExtent + (if (packed)\n'
			+ '\t\t\tBoundaries.NODE_PACK_MESH_BADGEMARK_LOWEST_SPACING\n'
			+ '\t\telse if (linked)\n\t\t\tBoundaries.NODE_PACK_MESH_BADGEMARK_TOGGLE_LOWEST_SPACING\n'
			+ '\t\telse\n\t\t\tBoundaries.NODE_PACK_MESH_CELL_EXTENT);\n\t}\n\n}',
			triviaWrite(SRC_VALUE_IF, CFG.replace(EXPR_WRAP_SECTION, ''))
		);
	}

	/**
	 * Gate discrimination for `hasBareParenTail` on the HARDLINE path: the same ladder as a Div
	 * NUMERATOR (`a + (ladder) / d`) leads with `(` but does not END with its `)`, so the tail is not
	 * a bare paren and the chain keeps its leading break. Dropping the `endsWithCloseDelim` conjunct
	 * makes this input glue — measured, so the conjunct is load-bearing here and not merely inherited
	 * from the hardline-free sibling. Source is written ALREADY BROKEN because the flat spelling of
	 * this shape is not a writer fixed point (a pre-existing, unrelated non-idempotence); this layout
	 * re-formats to itself.
	 */
	public function testHardlineParenDivTailDoesNotGlue(): Void {
		final src: String = 'class Sample {\n\tfunction run() {\n\t\tbadgeContainer.offset = baselineTextExtent\n'
			+ '\t\t\t+ (\n\t\t\t\tif (packed)\n\t\t\t\t\tBoundaries.NODE_PACK_MESH_BADGEMARK_LOWEST_SPACING\n'
			+ '\t\t\t\telse if (linked)\n\t\t\t\t\tBoundaries.NODE_PACK_MESH_BADGEMARK_TOGGLE_LOWEST_SPACING\n'
			+ '\t\t\t\telse\n\t\t\t\t\tBoundaries.NODE_PACK_MESH_CELL_EXTENT\n\t\t\t) / scaleDivisorValue;\n\t}\n}';
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tbadgeContainer.offset = baselineTextExtent\n'
			+ '\t\t\t+ (\n\t\t\t\tif (packed)\n\t\t\t\t\tBoundaries.NODE_PACK_MESH_BADGEMARK_LOWEST_SPACING\n'
			+ '\t\t\t\telse if (linked)\n\t\t\t\t\tBoundaries.NODE_PACK_MESH_BADGEMARK_TOGGLE_LOWEST_SPACING\n'
			+ '\t\t\t\telse\n\t\t\t\t\tBoundaries.NODE_PACK_MESH_CELL_EXTENT\n\t\t\t) / scaleDivisorValue;\n\t}\n\n}',
			triviaWrite(src, CFG)
		);
	}

	/** The glued shape re-formats to itself byte-for-byte. */
	public function testHardlineValueIfGlueIsIdempotent(): Void {
		final once: String = triviaWrite(SRC_VALUE_IF, CFG);
		Assert.equals(once, triviaWrite(once, CFG));
	}

	private inline function triviaWrite(src: String, cfg: String): String {
		return HxWriteFixture.triviaWrite(src, cfg);
	}

}

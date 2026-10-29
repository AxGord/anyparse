package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * The default `opBoolChain` / `opAddSubChain` cascade: a chain that fits stays on one line whatever its operands are,
 * a chain that does not fit puts every operator at the head of its own line, a broken `if (` condition keeps that
 * cascade instead of repacking its chain, and a chain whose only multi-line operand is the last one hugs it.
 * Every expected layout is also asserted as a fixed point.
 */
@:nullSafety(Strict)
final class HxChainDefaultCascadeTest extends Test {

	/** Tabs, 140 columns, and a condition wrap that opens the `(` of a condition that does not fit. */
	private static final CFG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, '
		+ '"conditionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": '
		+ '"exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}}';

	private static final FITS: String = 'class C {\n\tfunction a(c:Int):Bool {\n\t\treturn (c >= \'a\'.code && c <= \'z\'.code) '
		+ '|| (c >= \'A\'.code && c <= \'Z\'.code) || (c >= \'0\'.code && c <= \'9\'.code) || c == \'_\'.code;\n\t}\n}';
	private static final BOOL_FLAT: String = 'class C {\n\tfunction b():Bool {\n\t\treturn alphaValueNumberOne.isReadyForTheNextStep() '
		+ '&& betaValueNumberTwo.isReadyForTheNextStep() && gammaValueNumberThree.isReadyNow();\n\t}\n}';
	private static final BOOL_BROKEN: String = 'class C {\n\tfunction b():Bool {\n\t\treturn alphaValueNumberOne.isReadyForTheNextStep()\n'
		+ '\t\t\t&& betaValueNumberTwo.isReadyForTheNextStep()\n\t\t\t&& gammaValueNumberThree.isReadyNow();\n\t}\n}';
	private static final ADD_FLAT: String = 'class C {\n\tfunction c():String {\n\t\treturn \'first part of the longer message \' '
		+ '+ alphaValueNumberOne + \' second part of the message \' + betaValueNumberTwo + \' and the rest\';\n\t}\n}';
	private static final ADD_BROKEN: String = 'class C {\n\tfunction c():String {\n\t\treturn \'first part of the longer message \'\n'
		+ '\t\t\t+ alphaValueNumberOne\n\t\t\t+ \' second part of the message \'\n\t\t\t+ betaValueNumberTwo\n\t\t\t+ \' and the rest\';\n'
		+ '\t}\n}';
	private static final COND_FLAT: String = 'class C {\n\tfunction d() {\n\t\tif (alphaValueNumberOne > 0 && betaValueNumberTwo > 0 '
		+ '&& gammaValueNumberThree > 0 && deltaValueNumberFour > 0 && epsilonValueFive > 0 && zeta > 0) {\n\t\t\trun();\n\t\t}\n'
		+ '\t}\n}';
	private static final COND_BROKEN: String = 'class C {\n\tfunction d() {\n\t\tif (\n\t\t\talphaValueNumberOne > 0\n'
		+ '\t\t\t&& betaValueNumberTwo > 0\n\t\t\t&& gammaValueNumberThree > 0\n\t\t\t&& deltaValueNumberFour > 0\n'
		+ '\t\t\t&& epsilonValueFive > 0\n\t\t\t&& zeta > 0\n\t\t) {\n\t\t\trun();\n\t\t}\n\t}\n}';
	private static final HUG: String = 'class C {\n\tfunction e(xs:Array<Int>):Bool {\n\t\treturn xs.length > 0 && xs.foreach(t -> {\n'
		+ '\t\t\ttrace(t);\n\t\t\treturn true;\n\t\t});\n\t}\n}';

	public function new(): Void {
		super();
	}

	/** Four compound operands that fit the line stay on it: no soft threshold, no operand-complexity rule. */
	@:pin('control')
	@:killer('M-CHAIN-FITS-ONE-LINE')
	public function testFittingChainStaysOnOneLine(): Void {
		Assert.equals(FITS, HxWriteFixture.triviaWrite(FITS, CFG));
	}

	/** Three operands past the limit: every `&&` leads its own line rather than packing the first line full. */
	@:pin('control')
	@:killer('M-CHAIN-BREAK-PACKS')
	public function testOverflowingBoolChainBreaksAtEveryOperator(): Void {
		Assert.equals(BOOL_BROKEN, HxWriteFixture.triviaWrite(BOOL_FLAT, CFG));
		Assert.equals(BOOL_BROKEN, HxWriteFixture.triviaWrite(BOOL_BROKEN, CFG));
	}

	/** The `+` / `-` default is the same cascade. */
	@:pin('control')
	@:killer('M-CHAIN-BREAK-PACKS')
	public function testOverflowingAddChainBreaksAtEveryOperator(): Void {
		Assert.equals(ADD_BROKEN, HxWriteFixture.triviaWrite(ADD_FLAT, CFG));
		Assert.equals(ADD_BROKEN, HxWriteFixture.triviaWrite(ADD_BROKEN, CFG));
	}

	/** A condition whose `(` opened keeps the chain's own cascade: one operator per line at the condition's indent. */
	@:pin('control')
	@:killer('M-CONDWRAP-REPACKS')
	public function testBrokenConditionKeepsTheChainCascade(): Void {
		Assert.equals(COND_BROKEN, HxWriteFixture.triviaWrite(COND_FLAT, CFG));
		Assert.equals(COND_BROKEN, HxWriteFixture.triviaWrite(COND_BROKEN, CFG));
	}

	/** The lambda is the only operand that breaks and the glued line up to its `{` fits: the chain hugs it. */
	@:pin('control')
	@:killer('M-CHAIN-HUG-LAST')
	public function testMultilineLastOperandHugs(): Void {
		Assert.equals(HUG, HxWriteFixture.triviaWrite(HUG, CFG));
	}

	/** A line comment after the operand's `{` still leaves the glued line ending at that delimiter: the chain hugs it. */
	@:pin('control')
	@:killer('M-GLUE-COMMENT-AFTER-DELIM')
	public function testHugSurvivesALineCommentAfterTheDelimiter(): Void {
		final src: String = 'class C {\n\tfunction e(xs:Array<Int>):Bool {\n\t\treturn xs.length > 0 && xs.foreach(t -> { // why\n'
			+ '\t\t\ttrace(t);\n\t\t\treturn true;\n\t\t});\n\t}\n}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, CFG));
	}

	/** A `#if` region inside the last operand is not a delimiter the operand opened: the chain breaks at every operator. */
	@:pin('control')
	@:killer('M-HUG-ANY-FIRST-LINE')
	public function testConditionalRegionInTheLastOperandKeepsTheChainBroken(): Void {
		final glued: String = 'class C {\n\tfunction e(a:Dynamic, d:Dynamic, p:String):Bool {\n\t\treturn a.hasField(p) && d.isObject() && '
			+ '#if (haxe_ver >= 4.100)\n\t\t\t!Std.isOfType(d, String)\n\t\t#else\n\t\t\t!Std.is(d, String)\n\t\t#end;\n\t}\n}';
		final broken: String = 'class C {\n\tfunction e(a:Dynamic, d:Dynamic, p:String):Bool {\n\t\treturn a.hasField(p)\n'
			+ '\t\t\t&& d.isObject()\n\t\t\t&& #if (haxe_ver >= 4.100)\n\t\t\t\t!Std.isOfType(d, String)\n\t\t\t#else\n'
			+ '\t\t\t\t!Std.is(d, String)\n\t\t\t#end;\n\t}\n}';
		Assert.equals(broken, HxWriteFixture.triviaWrite(glued, CFG));
		Assert.equals(broken, HxWriteFixture.triviaWrite(broken, CFG));
	}

	/** A `switch` subject is one line whatever its width: the subject site forces `NoWrap` on the chain in it. */
	@:pin('control')
	@:killer('M-CHAIN-FORCE-KEEPS-OWN-RULES')
	public function testSwitchSubjectChainStaysOnOneLine(): Void {
		final src: String = 'class C {\n\tfunction g() {\n'
			+ '\t\tswitch (alphaValue00 + alphaValue01 + alphaValue02 + alphaValue03 + alphaValue04 + alphaValue05 + '
			+ 'alphaValue06 + alphaValue07 + alphaValue08 + alphaValue09) {\n\t\t\tcase _:\n\t\t}\n\t}\n}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, CFG));
	}

	/** A chain inside `${…}` stays on one line even under a cascade that always breaks: the interpolation forces `NoWrap`. */
	@:pin('control')
	@:killer('M-CHAIN-FORCE-KEEPS-OWN-RULES')
	public function testInterpolatedChainStaysOnOneLine(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\ttrace(\'point $${topRightPointX - 7.5},$$topRightPointY\');\n\t}\n}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, '{"wrapping": {"opAddSubChain": {"defaultWrap": "onePerLine", "rules": []}}}'));
	}

	/** An expression paren inside a condition lays its chain out by `expressionWrapping`, not by the chain cascade. */
	@:pin('control')
	@:killer('M-CHAIN-FORCE-KEEPS-OWN-RULES')
	public function testExpressionParenInAConditionFollowsExpressionWrapping(): Void {
		final cfg: String = '{"wrapping": {"maxLineLength": 80, "expressionWrapping": {"defaultWrap": "noWrap", "rules": [{"conditions": '
			+ '[{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLineWithLeadingBreak"}]}}}';
		final src: String = 'class Main {\n\tstatic function main() {\n\t\tif ((veryLongExpressionAlpha + veryLongExpressionBravo + '
			+ 'veryLongExpressionCharlie + veryLongExpressionDelta) > threshold) {\n\t\t\tdoSomething();\n\t\t}\n\t}\n}';
		final opened: String = 'class Main {\n\tstatic function main() {\n\t\tif ((\n'
			+ '\t\t\tveryLongExpressionAlpha + veryLongExpressionBravo\n\t\t\t+ veryLongExpressionCharlie + '
			+ 'veryLongExpressionDelta\n\t\t) > threshold) {\n\t\t\tdoSomething();\n\t\t}\n\t}\n}';
		Assert.equals(opened, HxWriteFixture.triviaWrite(src, cfg));
	}

	/** A `for` head that breaks keeps the chain's own cascade too: one operator per line at the head's indent. */
	@:pin('control')
	@:killer('M-CONDWRAP-FOR-REPACKS')
	public function testBrokenForHeadKeepsTheChainCascade(): Void {
		final flat: String = 'class C {\n\tfunction d() {\n'
			+ '\t\tfor (i in alphaValueNumberOne + betaValueNumberTwo + gammaValueNumberThree + deltaValueNumberFour + '
			+ 'epsilonValueFive + zetaValueSix + etaValueSeven...omega) {\n\t\t\trun();\n\t\t}\n\t}\n}';
		final broken: String = 'class C {\n\tfunction d() {\n\t\tfor (\n\t\t\ti in alphaValueNumberOne\n\t\t\t+ betaValueNumberTwo\n'
			+ '\t\t\t+ gammaValueNumberThree\n\t\t\t+ deltaValueNumberFour\n\t\t\t+ epsilonValueFive\n\t\t\t+ zetaValueSix\n'
			+ '\t\t\t+ etaValueSeven...omega\n\t\t) {\n\t\t\trun();\n\t\t}\n\t}\n}';
		Assert.equals(broken, HxWriteFixture.triviaWrite(flat, CFG));
		Assert.equals(broken, HxWriteFixture.triviaWrite(broken, CFG));
	}

}

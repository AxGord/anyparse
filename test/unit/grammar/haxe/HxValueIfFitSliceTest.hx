package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * omega-value-if-fit (`sameLine.expressionIfFit`): a value-position `if` / `else if` chain is
 * decided by FIT instead of always exploding. Flat on one line when it fits at its column;
 * otherwise the EXACT layout `expressionIf: next` produces on its own -- each branch value on its
 * own indented line, `else` back at the `if`'s indent.
 *
 * The knob is the sibling of `expressionIfArrowBodyReflow` and shares its seams; the two differ in
 * the BROKEN shape (the arrow knob glues each value to its condition, this one keeps the policy
 * layout) and in reach (arrow body only vs every value-`if`). An arrow body under both keeps the
 * arrow shape -- that gate is checked first.
 */
@:nullSafety(Strict)
final class HxValueIfFitSliceTest extends Test {

	private static final BASE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}';
	private static final ON: String = '$BASE, "sameLine": {"expressionIf": "next", "expressionIfFit": true}}';
	private static final OFF: String = '$BASE, "sameLine": {"expressionIf": "next"}}';
	private static final ARROW_BOTH: String =
		'$BASE, "sameLine": {"expressionIf": "next", "expressionIfFit": true, "expressionIfArrowBodyReflow": true}}';
	private static final CAP2: String =
		'$BASE, "sameLine": {"expressionIf": "next", "expressionIfFit": true, "expressionIfFitMaxBranches": 2}}';
	private static final CAP3: String =
		'$BASE, "sameLine": {"expressionIf": "next", "expressionIfFit": true, "expressionIfFitMaxBranches": 3}}';
	private static final CAP2_KNOB_OFF: String = '$BASE, "sameLine": {"expressionIf": "next", "expressionIfFitMaxBranches": 2}}';

	public function new(): Void {
		super();
	}

	/** A chain that fits at its column collapses to one line. */
	public function testFittingAssignmentCollapses(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal a:Int = if (c) 1 else if (d) 2 else 3;\n\t}\n}';
		Assert.equals(src, triviaWrite(src, ON));
	}

	/** The same source under the knob OFF keeps exploding -- the knob IS what collapses it. */
	public function testFittingAssignmentExplodesWithKnobOff(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal a:Int = if (c) 1 else if (d) 2 else 3;\n\t}\n}';
		final out: String =
			'class C {\n\tfunction test() {\n\t\tfinal a:Int = if (c)\n\t\t\t1\n\t\telse if (d)\n\t\t\t2\n\t\telse\n\t\t\t3;\n\t}\n}';
		Assert.equals(out, triviaWrite(src, OFF));
	}

	/** `return` is a value position too. */
	public function testFittingReturnCollapses(): Void {
		final src: String = 'class C {\n\tfunction test():Int {\n\t\treturn if (c) 1 else if (d) 2 else 3;\n\t}\n}';
		Assert.equals(src, triviaWrite(src, ON));
	}

	/** So is a sole call argument. */
	public function testFittingCallArgumentCollapses(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\titems.push(if (c) 1 else if (d) 2 else 3);\n\t}\n}';
		Assert.equals(src, triviaWrite(src, ON));
	}

	/**
	 * A chain too wide for one line keeps the POLICY layout -- every branch value on its own
	 * indented line, `else` at the `if`'s indent. This is the half the cond-fit group used to
	 * corrupt: it wraps the condition plus the THEN body only, so its own fit answer glued the
	 * then-value while the `else` gaps broke, and the chain came out a ragged hybrid.
	 */
	public function testNonFittingKeepsPolicyLayout(): Void {
		final v1: String = '\'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\'';
		final v2: String = '\'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\'';
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal a:String = if (c)\n\t\t\t$v1\n\t\telse\n\t\t\t$v2;\n\t}\n}';
		Assert.equals(src, triviaWrite(src, ON));
	}

	/** A STATEMENT-position if/else is not a value-if and is untouched by the knob. */
	public function testStatementIfUntouched(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tif (c)\n\t\t\tdoA();\n\t\telse\n\t\t\tdoB();\n\t}\n}';
		Assert.equals(src, triviaWrite(src, ON));
	}

	/** With BOTH knobs on, an arrow body keeps the ARROW shape -- its gate is checked first. */
	public function testArrowBodyKeepsArrowShapeUnderBothKnobs(): Void {
		final v1: String = '\'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\'';
		final v2: String = '\'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\'';
		final src: String = 'class C {\n\tfunction test() {\n\t\txs.map(x ->\n\t\t\tif (c) $v1\n\t\t\telse $v2\n\t\t);\n\t}\n}';
		Assert.equals(src, triviaWrite(src, ARROW_BOTH));
	}

	/**
	 * omega-value-if-fit branch cap: a THREE-branch chain that fits is refused by
	 * `expressionIfFitMaxBranches: 2` and keeps the policy layout. Width is not the discriminator
	 * here -- this chain fits 140 columns with room to spare; the count is.
	 */
	public function testBranchCapRefusesThreeBranchChain(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal a:Int = if (c) 1 else if (d) 2 else 3;\n\t}\n}';
		final out: String =
			'class C {\n\tfunction test() {\n\t\tfinal a:Int = if (c)\n\t\t\t1\n\t\telse if (d)\n\t\t\t2\n\t\telse\n\t\t\t3;\n\t}\n}';
		Assert.equals(out, triviaWrite(src, CAP2));
	}

	/** The same cap leaves a TWO-branch chain collapsing -- the cap narrows the knob, it does not disable it. */
	public function testBranchCapAllowsTwoBranchChain(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal a:Int = if (c) 1 else 2;\n\t}\n}';
		Assert.equals(src, triviaWrite(src, CAP2));
	}

	/** A source-exploded two-branch chain still COLLAPSES under the cap -- the knob keeps working below it. */
	public function testBranchCapCollapsesExplodedTwoBranchChain(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal a:Int = if (c)\n\t\t\t1\n\t\telse\n\t\t\t2;\n\t}\n}';
		final out: String = 'class C {\n\tfunction test() {\n\t\tfinal a:Int = if (c) 1 else 2;\n\t}\n}';
		Assert.equals(out, triviaWrite(src, CAP2));
	}

	/**
	 * An `else if` with no trailing `else` is TWO value branches, not three -- the count is over
	 * branches, not over `if` keywords, so this one passes a cap of 2.
	 */
	public function testBranchCapCountsBranchesNotIfKeywords(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal a:Int = if (c) 1 else if (d) 2;\n\t}\n}';
		Assert.equals(src, triviaWrite(src, CAP2));
	}

	/** Raising the cap to 3 lets the same three-branch chain collapse again. */
	public function testBranchCapThreeAllowsThreeBranchChain(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal a:Int = if (c) 1 else if (d) 2 else 3;\n\t}\n}';
		Assert.equals(src, triviaWrite(src, CAP3));
	}

	/**
	 * ★ The refusal is CHAIN-WIDE. A four-branch chain under a cap of 3 must not render with its
	 * three-branch tail collapsed and its head in policy layout -- that hybrid is exactly what the
	 * `_aifBlocked` propagation exists to prevent, and only a nested-tail assertion catches it.
	 */
	public function testBranchCapRefusalIsChainWide(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal a:Int = if (c) 1 else if (d) 2 else if (e) 3 else 4;\n\t}\n}';
		final out: String = 'class C {\n\tfunction test() {\n\t\tfinal a:Int = if (c)\n\t\t\t1\n\t\telse if (d)'
			+ '\n\t\t\t2\n\t\telse if (e)\n\t\t\t3\n\t\telse\n\t\t\t4;\n\t}\n}';
		Assert.equals(out, triviaWrite(src, CAP3));
	}

	/** The cap is inert while the knob itself is off -- a config may set it once and toggle the knob. */
	public function testBranchCapInertWithKnobOff(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal a:Int = if (c) 1 else 2;\n\t}\n}';
		final out: String = 'class C {\n\tfunction test() {\n\t\tfinal a:Int = if (c)\n\t\t\t1\n\t\telse\n\t\t\t2;\n\t}\n}';
		Assert.equals(out, triviaWrite(src, CAP2_KNOB_OFF));
	}

	private inline function triviaWrite(src: String, config: String): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

}

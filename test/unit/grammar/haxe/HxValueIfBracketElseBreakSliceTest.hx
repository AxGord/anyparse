package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * Under `sameLine.expressionIf: next` a value-`if` whose branch is a `[ … ]` literal breaks before its `else`
 * like every other non-curly branch: the branch value sits on its own line one indent deeper, so its `]` can
 * never be in the column the `else` belongs to.
 *
 * The reported input is `return if (a) [1] else if (b) [] else [2];`, found while sweeping the anyparse tree
 * itself: `hxq fmt` moved every branch value onto its own line and left each `else` glued to the `]` in front of
 * it (`[1] else if (b)` / `[] else`). The pre-`else` gap read the source's own break slot after a bracket close
 * (`SameOnBlock` routed a `]` to `Keep`), so a flat source kept `] else` while the body placement it had
 * answered for had already moved: one construct, two layouts, decided by how the source happened to be typed.
 *
 * The second half is `sameLine.expressionIfFit`: its soft pre-`else` seam refused every BLOCK previous body,
 * a `[ … ]` literal included, and that refusal is what had kept a fitting `if (a) [] else [2]` on one line —
 * by way of the source slot it then read. The refusal exists for the `} else` glue a curly close owns and a
 * bracket close does not, so it is curly-only now and a bracket chain answers the same fit question every
 * other value chain answers.
 *
 * The expected strings are the `next` ladder the config documentation states (each branch value on its own
 * indented line, `else` back at the `if`'s indent), typed from that rule, not read back from the writer.
 * `sameLine.expressionIfWithBrackets` is absent everywhere here: with it the `[` hugs its head and `] else`
 * IS the close (`HxValueIfBracketHugSliceTest`).
 */
@:nullSafety(Strict)
final class HxValueIfBracketElseBreakSliceTest extends Test {

	/** Pony-shaped config with `sameLine.expressionIf: next` — what both real trees set. */
	private static final CFG_NEXT: String = cfg(false);

	/** The same config with `sameLine.expressionIfFit` on, capped at two value branches — the client's setting. */
	private static final CFG_FIT: String = cfg(true);

	/** `CFG_FIT` with the bracket hug on: a `]` the knob glues still owns its `] else`, fit or no fit. */
	private static final CFG_FIT_HUG: String = cfg(true, true);

	/** The reported chain, flat: every gap inline in the source, so no answer can come from reading it back. */
	private static final CHAIN_FLAT: String =
		'class C {\n\tfunction f(a: Bool, b: Bool): Array<Int> {\n\t\treturn if (a) [1] else if (b) [] else [2];\n\t}\n}';

	/** The `next` ladder: each value one indent in, each `else` at the `if`'s own indent. */
	private static final CHAIN_LADDER: String = 'class C {\n\tfunction f(a: Bool, b: Bool): Array<Int> {\n'
		+ '\t\treturn if (a)\n\t\t\t[1]\n\t\telse if (b)\n\t\t\t[]\n\t\telse\n\t\t\t[2];\n\t}\n}';

	/** A two-branch bracket chain that fits its line. */
	private static final PAIR_FLAT: String = 'class C {\n\tfunction g(a: Bool): Array<Int> {\n\t\treturn if (a) [] else [2];\n\t}\n}';

	/** …and the same chain as the `next` ladder. */
	private static final PAIR_LADDER: String =
		'class C {\n\tfunction g(a: Bool): Array<Int> {\n\t\treturn if (a)\n\t\t\t[]\n\t\telse\n\t\t\t[2];\n\t}\n}';

	/** A two-branch bracket chain over the 140 columns, written flat. */
	private static final WIDE_FLAT: String = 'class C {\n\tfunction w(a: Bool): Array<String> {\n'
		+ '\t\treturn if (a) [firstElementNameThatIsLongEnough, secondElementNameThatIsLongEnough] '
		+ 'else [thirdElementNameThatIsLongEnough, fourthElementName];\n\t}\n}';

	/** …which no fit can save: the `next` ladder, the `]` and the `else` on lines of their own. */
	private static final WIDE_LADDER: String = 'class C {\n\tfunction w(a: Bool): Array<String> {\n'
		+ '\t\treturn if (a)\n\t\t\t[firstElementNameThatIsLongEnough, secondElementNameThatIsLongEnough]\n'
		+ '\t\telse\n\t\t\t[thirdElementNameThatIsLongEnough, fourthElementName];\n\t}\n}';

	/** What the hug knob made of `WIDE_FLAT` under the fit knob before the seam stopped refusing brackets: unchanged. */
	private static final WIDE_HUGGED: String = 'class C {\n\tfunction w(a: Bool): Array<String> {\n\t\treturn\n'
		+ '\t\t\tif (a) [firstElementNameThatIsLongEnough, secondElementNameThatIsLongEnough] '
		+ 'else [thirdElementNameThatIsLongEnough, fourthElementName];\n\t}\n}';

	public function new(): Void {
		super();
	}

	/** The reported input: a flat source reaches the ladder, no `] else` left anywhere. RED at base. */
	@:pin('control')
	@:killer('M-NONCURLY-SAME-DROP')
	public function testAFlatBracketChainBreaksBeforeEveryElse(): Void {
		Assert.equals(CHAIN_LADDER, HxWriteFixture.triviaWrite(CHAIN_FLAT, CFG_NEXT));
		Assert.equals(PAIR_LADDER, HxWriteFixture.triviaWrite(PAIR_FLAT, CFG_NEXT));
	}

	/** The ladder is a fixed point: a second write changes nothing. Green at base — the source break was kept. */
	@:pin('guard')
	public function testTheLadderIsAFixedPoint(): Void {
		Assert.equals(CHAIN_LADDER, HxWriteFixture.triviaWrite(CHAIN_LADDER, CFG_NEXT));
		Assert.equals(PAIR_LADDER, HxWriteFixture.triviaWrite(PAIR_LADDER, CFG_NEXT));
	}

	/** Over the branch cap the fit knob keeps the exact `next` layout, so the three-branch chain is the ladder too. RED at base. */
	@:pin('control')
	@:killer('M-NONCURLY-SAME-DROP')
	public function testOverTheBranchCapTheFitKnobKeepsTheLadder(): Void {
		Assert.equals(CHAIN_LADDER, HxWriteFixture.triviaWrite(CHAIN_FLAT, CFG_FIT));
	}

	/** A fitting two-branch bracket chain stays on one line, from a flat source. Green at base, by way of the source slot. */
	@:pin('guard')
	public function testAFittingBracketPairStaysFlat(): Void {
		Assert.equals(PAIR_FLAT, HxWriteFixture.triviaWrite(PAIR_FLAT, CFG_FIT));
	}

	/**
	 * …and from the ladder: the fit question is answered by width, never by the source break. RED at base, where
	 * the seam refused a bracket previous body and read the source's `else` line instead.
	 */
	@:pin('control')
	@:killer('M-VIF-SEAM-BRACKET-REFUSED')
	public function testAFittingBracketLadderCollapses(): Void {
		Assert.equals(PAIR_FLAT, HxWriteFixture.triviaWrite(PAIR_LADDER, CFG_FIT));
	}

	/**
	 * A pair that does not fit breaks into the ladder, its `else` back at the `if`'s indent. RED at base, where
	 * BOTH seams glued it; neither arm alone reaches it, since the soft fit seam breaks here whatever the
	 * bracket arm answers and the bracket arm breaks it whenever the fit seam is refused.
	 */
	@:pin('guard')
	public function testAWideBracketPairBreaksIntoTheLadder(): Void {
		Assert.equals(WIDE_LADDER, HxWriteFixture.triviaWrite(WIDE_FLAT, CFG_FIT));
		Assert.equals(WIDE_LADDER, HxWriteFixture.triviaWrite(WIDE_LADDER, CFG_FIT));
	}

	/**
	 * Under the bracket hug the soft fit seam stays refused after a glued `]`: the knob's close is `] else`, and
	 * a seam the fit group breaks would split it into `]` / `else [`. Byte-identical to the base binary.
	 */
	@:pin('control')
	@:killer('M-VIF-SEAM-GLUE-BLIND')
	public function testUnderTheHugTheGluedCloseKeepsItsElse(): Void {
		Assert.equals(WIDE_HUGGED, HxWriteFixture.triviaWrite(WIDE_FLAT, CFG_FIT_HUG));
	}

	/** Pony-shaped config text with `sameLine.expressionIfFit` and the bracket hug as the two variables. */
	private static function cfg(fit: Bool, hug: Bool = false): String {
		final fitKeys: String = fit ? ', "expressionIfFit": true, "expressionIfFitMaxBranches": 2' : '';
		final hugKey: String = hug ? ', "expressionIfWithBrackets": true' : '';
		return '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, '
			+ '"arrayWrap": {"defaultWrap": "ignore", "rules": []}}, "whitespace": {"typeHintColonPolicy": "after"}, '
			+ '"sameLine": {"ifBody": "fitLine", "functionBody": "fitLine", "expressionIf": "next"$fitKeys$hugKey}}';
	}

}

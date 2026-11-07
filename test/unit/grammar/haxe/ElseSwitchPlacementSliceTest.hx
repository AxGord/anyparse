package unit.grammar.haxe;

import anyparse.format.KeywordPlacement;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * `sameLine.elseSwitch` - the `elseIf` twin for the OTHER keyword-headed statement an `else`
 * idiomatically carries. The user asked for it by name, choosing `same`, because a `switch` else-body reads like `else if`, and
 * Pony writes every one of its own in the two-line shape, none on one line (the brief's census, which had them split, was wrong).
 *
 * The THEN branch is armed as well, after the user read a pair of `switch` branches coming
 * back with one glued and one on its own line and named the defect himself: SYMMETRICALLY -
 * the two halves of one `if`/`else` must be laid out the same way. That half
 * owns a second seam, the close: a glued `switch` ends with a `}` in the `if` head's own
 * column, so the `else` must cuddle it the way it cuddles a block's. Both seams decline
 * together on a captured comment, which is what the two comment pins below separate.
 *
 * Its default is `Same`: no placement reads the source layout.
 *
 * ⚠️ EVERY assertion here goes through the TRIVIA writer. The plain writer captures no
 * comment slots, so a comment assertion against it FAILS vacuously - as this very class's
 * first draft did. Trivia mode is
 * also what `hxq fmt` and the Pony sweep run, so it is the mode the knob was asked for.
 */
@:nullSafety(Strict)
class ElseSwitchPlacementSliceTest extends Test {

	private static final BASE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}';
	private static final DEFAULT: String = '$BASE}';
	private static final SAME: String = '$BASE, "sameLine": {"elseSwitch": "same"}}';
	private static final NEXT: String = '$BASE, "sameLine": {"elseSwitch": "next"}}';
	private static final EXPLICIT_KEEP: String = '$BASE, "sameLine": {"elseSwitch": "keep"}}';

	/**
	 * The value-`if` needs `expressionIf: next` under it, or the branch policies default to `Same` and glue every
	 * branch on their own: the knob then decides nothing and an assertion on it passes with the feature disabled.
	 */
	private static final SAME_EXPR_NEXT: String = '$BASE, "sameLine": {"elseSwitch": "same", "expressionIf": "next"}}';

	/** An `else` whose body is a `switch`, written on the line AFTER the `else` - Pony's shape. */
	private static final TWO_LINE: String = 'class F {\n\tfunction f(s:String):Int {\n\t\tif (s == \'\')\n\t\t\treturn 0;\n'
		+ '\t\telse\n\t\t\tswitch s {\n\t\t\t\tcase _:\n\t\t\t\t\treturn 1;\n\t\t\t}\n\t}\n}';

	/** BOTH branches a `switch`, both on the line after their keyword - the shape the user reported. */
	private static final BOTH_TWO_LINE: String = 'class F {\n\tfunction f(s:String):Int {\n\t\tif (s == \'\')\n'
		+ '\t\t\tswitch s {\n\t\t\t\tcase _:\n\t\t\t\t\treturn 1;\n\t\t\t}\n\t\telse\n\t\t\tswitch s {\n'
		+ '\t\t\t\tcase _:\n\t\t\t\t\treturn 2;\n\t\t\t}\n\t}\n}';

	/** The same pair with a `//` comment between the `if` head and the then-`switch`. */
	private static final BOTH_TWO_LINE_COMMENTED: String = 'class F {\n\tfunction f(s:String):Int {\n\t\tif (s == \'\')\n'
		+ '\t\t\t// why\n\t\t\tswitch s {\n\t\t\t\tcase _:\n\t\t\t\t\treturn 1;\n\t\t\t}\n\t\telse\n\t\t\tswitch s {\n'
		+ '\t\t\t\tcase _:\n\t\t\t\t\treturn 2;\n\t\t\t}\n\t}\n}';

	public function testDefaultIsSame(): Void {
		final defaults: HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(KeywordPlacement.Same, defaults.elseSwitch, 'a switch branch glues to its keyword');
		Assert.equals(KeywordPlacement.Same, defaults.elseIf, 'its older twin keeps the default it shipped with');
	}

	/** The default is `same`: the `switch` glues to its `else` with no key in the config. */
	@:pin('control')
	@:killer('M-ELSE-SWITCH-TESTS-NONE')
	public function testTheDefaultGluesTheSwitchToItsElse(): Void {
		final out: String = HxWriteFixture.triviaWrite(TWO_LINE, DEFAULT);
		Assert.isTrue(out.indexOf('else switch s {') != -1, 'expected `else switch s {` in: <$out>');
		Assert.equals(HxWriteFixture.triviaWrite(TWO_LINE, SAME), out);
	}

	@:pin('control')
	@:killer('M-ELSE-SWITCH-TESTS-NONE')
	public function testSamePlacesTheSwitchOnTheElseLine(): Void {
		final out: String = HxWriteFixture.triviaWrite(TWO_LINE, SAME);
		Assert.isTrue(out.indexOf('else switch s {') != -1, 'expected `else switch s {` in: <$out>');
		Assert.isTrue(out.indexOf('else\n\t\t\tswitch') == -1, 'did not expect the two-line shape in: <$out>');
	}

	public function testNextMovesTheSwitchOffTheElseLine(): Void {
		final oneLine: String = 'class F {\n\tfunction f(s:String):Int {\n\t\tif (s == \'\')\n\t\t\treturn 0;\n'
			+ '\t\telse switch s {\n\t\t\tcase _:\n\t\t\t\treturn 1;\n\t\t}\n\t}\n}';
		final out: String = HxWriteFixture.triviaWrite(oneLine, NEXT);
		Assert.isTrue(out.indexOf('else switch') == -1, 'expected the switch pushed off the else line in: <$out>');
	}

	/** An explicit `"keep"` is unsupported and leaves the default, so it writes what an absent key writes. */
	public function testExplicitKeepAgreesWithTheAbsentKey(): Void {
		Assert.equals(HxWriteFixture.triviaWrite(TWO_LINE, DEFAULT), HxWriteFixture.triviaWrite(TWO_LINE, EXPLICIT_KEEP));
	}

	/**
	 * The knob reaches the value-`if` too (`HxIfExpr`), not only the statement form - asserted
	 * against the SAME input under the same config minus the knob, because `expressionElseBody`
	 * defaults to `Same` and glues that branch on its own. Under the plain `SAME` config this
	 * test passed with the whole feature removed.
	 */
	public function testTheValueIfCarriesItAsWell(): Void {
		final src: String = 'class F {\n\tfunction f(s:String):Int {\n\t\treturn if (s == \'\')\n\t\t\t0;\n'
			+ '\t\telse\n\t\t\tswitch s {\n\t\t\t\tcase _:\n\t\t\t\t\t1;\n\t\t\t}\n\t}\n}';
		final out: String = HxWriteFixture.triviaWrite(src, SAME_EXPR_NEXT);
		Assert.isTrue(out.indexOf('else switch s {') != -1, 'expected the value-if else to carry it too in: <$out>');

	}

	/** An `else if` chain that ENDS in an `else switch`: the chain links keep their own handler. */
	@:pin('control')
	@:killer('M-ELSE-SWITCH-TESTS-NONE')
	public function testAnElseIfChainEndingInElseSwitch(): Void {
		final src: String = 'class F {\n\tfunction f(s:String, b:Bool):Int {\n\t\tif (b)\n\t\t\treturn 0;\n'
			+ '\t\telse if (s == \'\')\n\t\t\treturn 1;\n\t\telse\n\t\t\tswitch s {\n\t\t\t\tcase _:\n\t\t\t\t\treturn 2;\n\t\t\t}\n\t}\n}';
		final out: String = HxWriteFixture.triviaWrite(src, SAME);
		Assert.isTrue(out.indexOf('else if (s == \'\')') != -1, 'the else-if link stays inline in: <$out>');
		Assert.isTrue(out.indexOf('else switch s {') != -1, 'the tail becomes `else switch` in: <$out>');
	}

	/**
	 * A comment between `else` and the `switch` keeps the source BYTE FOR BYTE — indentation included:
	 * the glue's `Same` layout writes the comment and puts the `switch` below it, one step in.
	 *
	 * Exact bytes rather than "the comment is still there": a `Same` layout that writes the comment
	 * but drops the body back to the keyword's column keeps the comment too, and only exact equality
	 * separates the two.
	 */
	@:pin('control')
	@:killer('M-KW-SAME-UNNESTED')
	public function testACommentBetweenElseAndSwitchKeepsTheSourceShape(): Void {
		final src: String = 'class F {\n\tfunction f(s:String):Int {\n\t\tif (s == \'\')\n\t\t\treturn 0;\n'
			+ '\t\telse\n\t\t\t// why\n\t\t\tswitch s {\n\t\t\t\tcase _:\n\t\t\t\t\treturn 1;\n\t\t\t}\n\t}\n}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, SAME));
	}

	/**
	 * The user's own rule, in his words, is that the two halves of one `if`/`else` must be laid
	 * out SYMMETRICALLY - the same way. The knob armed only the `else` half, so a pair of `switch`
	 * branches came back with one glued and one on its own line. The whole target block is asserted
	 * BYTE for byte because two independent seams have to fire: the then-`switch` hugging the `if`
	 * head, and the `}` it closes with cuddling the `else` the way a block's close already does.
	 */
	@:pin('control')
	@:killer('M-ELSE-SWITCH-CLOSE-NONE')
	public function testSameGluesTheThenSwitchToItsIfHeadToo(): Void {
		final expected: String = 'class F {\n\tfunction f(s:String):Int {\n\t\tif (s == \'\') switch s {\n\t\t\tcase _:\n'
			+ '\t\t\t\treturn 1;\n\t\t} else switch s {\n\t\t\tcase _:\n\t\t\t\treturn 2;\n\t\t}\n\t}\n}';
		Assert.equals(expected, HxWriteFixture.triviaWrite(BOTH_TWO_LINE, SAME));
	}

	/**
	 * The value-`if` gets the same pair of seams, so the knob still reaches both grammar forms.
	 * Under `expressionIf: next`: without it both branch policies are `Same` already and the
	 * assertion holds with the knob switched off - which is how the first draft of this test
	 * survived `M-ELSE-SWITCH-TESTS-NONE`.
	 */
	@:pin('control')
	@:killer('M-ELSE-SWITCH-TESTS-NONE')
	public function testTheValueIfThenBranchGluesAsWell(): Void {
		final src: String = 'class F {\n\tfunction f(s:String):Int {\n\t\treturn if (s == \'\')\n\t\t\tswitch s {\n'
			+ '\t\t\t\tcase _:\n\t\t\t\t\t1;\n\t\t\t}\n\t\telse\n\t\t\tswitch s {\n\t\t\t\tcase _:\n\t\t\t\t\t2;\n\t\t\t}\n\t}\n}';
		final expected: String = 'class F {\n\tfunction f(s:String):Int {\n\t\treturn if (s == \'\') switch s {\n\t\t\tcase _: 1;\n'
			+ '\t\t} else switch s {\n\t\t\tcase _: 2;\n\t\t}\n\t}\n}';
		Assert.equals(expected, HxWriteFixture.triviaWrite(src, SAME_EXPR_NEXT));
	}

	/** Both seams fire under the default, as under `same`: both switches glue and the `else` cuddles the first close. */
	public function testTheDefaultGluesBothSwitches(): Void {
		Assert.equals(HxWriteFixture.triviaWrite(BOTH_TWO_LINE, SAME), HxWriteFixture.triviaWrite(BOTH_TWO_LINE, DEFAULT));
	}

	/**
	 * `next` must not cuddle the `else` either. The close-side seam asks the KNOB, not just the
	 * branch's ctor: at `next` the same `switch` sits one indent deeper than the `if` head, so a
	 * `}` there is not the head's own column and `} else` would be wrong.
	 */
	public function testNextLeavesTheElseOnItsOwnLine(): Void {
		final out: String = HxWriteFixture.triviaWrite(BOTH_TWO_LINE, NEXT);
		Assert.equals(BOTH_TWO_LINE, out);
		Assert.isTrue(out.indexOf('} else') == -1, 'the close must not cuddle an unglued switch in: <$out>');
	}

	/**
	 * A comment between the `if` head and the then-`switch` declines the glue - and the close-side
	 * seam has to decline WITH it. Without that half the `}` still cuddled the `else`, under a
	 * `switch` that had never moved up, and the `else` body came back a whole indent level
	 * shallower than its own close. Asserted byte for byte, for the reason the `else`-side comment
	 * pin above records: presence alone cannot see the layout.
	 */
	@:pin('control')
	@:killer('M-ELSE-SWITCH-CLOSE-COMMENT')
	public function testACommentBeforeTheThenSwitchDeclinesBothSeams(): Void {
		final expected: String = 'class F {\n\tfunction f(s:String):Int {\n\t\tif (s == \'\')\n\t\t\t// why\n\t\t\tswitch s {\n'
			+ '\t\t\t\tcase _:\n\t\t\t\t\treturn 1;\n\t\t\t}\n\t\telse switch s {\n\t\t\tcase _:\n\t\t\t\treturn 2;\n\t\t}\n\t}\n}';
		Assert.equals(expected, HxWriteFixture.triviaWrite(BOTH_TWO_LINE_COMMENTED, SAME));
	}

	public function testTheRewriteIsIdempotent(): Void {
		final once: String = HxWriteFixture.triviaWrite(TWO_LINE, SAME);
		Assert.equals(once, HxWriteFixture.triviaWrite(once, SAME));
		final bothOnce: String = HxWriteFixture.triviaWrite(BOTH_TWO_LINE, SAME);
		Assert.equals(bothOnce, HxWriteFixture.triviaWrite(bothOnce, SAME));
	}

}

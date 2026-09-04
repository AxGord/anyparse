package unit.grammar.haxe;

import anyparse.format.KeywordPlacement;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * `sameLine.elseSwitch` - the `elseIf` twin for the OTHER keyword-headed statement an `else`
 * idiomatically carries. The user asked for it by name (2026-09-03), choosing `same`,
 * because a `switch` else-body reads like `else if`, and Pony writes ten of them - ALL TEN in
 * the two-line shape, none on one line (parent census on `44c95603`; the brief's "10 one-line /
 * 10 two-line / 1 braced" was wrong).
 *
 * Its default is `Keep`, NOT `Same` as `elseIf`'s is, and that asymmetry is deliberate: `elseIf`
 * has shipped with `Same` since it existed, while this knob is new and must leave every existing
 * config's bytes alone. `testDefaultIsKeepNotSame` is the pin on that, and it is the one this
 * class exists for - a `Same` default would silently reformat every project that never asked.
 *
 * ⚠️ EVERY assertion here goes through the TRIVIA writer. The plain writer captures no
 * source-newline and no comment slots, so a `Keep` assertion against it passes vacuously and a
 * comment assertion FAILS vacuously - measured, on this very class's first draft. Trivia mode is
 * also what `hxq fmt` and the Pony sweep run, so it is the mode the knob was asked for.
 */
@:nullSafety(Strict)
class ElseSwitchPlacementSliceTest extends Test {

	private static final BASE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}';
	private static final KEEP: String = '$BASE}';
	private static final SAME: String = '$BASE, "sameLine": {"elseSwitch": "same"}}';
	private static final NEXT: String = '$BASE, "sameLine": {"elseSwitch": "next"}}';
	private static final EXPLICIT_KEEP: String = '$BASE, "sameLine": {"elseSwitch": "keep"}}';

	/** An `else` whose body is a `switch`, written on the line AFTER the `else` - Pony's shape. */
	private static final TWO_LINE: String = 'class F {\n\tfunction f(s:String):Int {\n\t\tif (s == \'\')\n\t\t\treturn 0;\n'
		+ '\t\telse\n\t\t\tswitch s {\n\t\t\t\tcase _:\n\t\t\t\t\treturn 1;\n\t\t\t}\n\t}\n}';

	public function testDefaultIsKeepNotSame(): Void {
		final defaults: HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(KeywordPlacement.Keep, defaults.elseSwitch, 'a new knob must default to no opinion');
		Assert.equals(KeywordPlacement.Same, defaults.elseIf, 'its older twin keeps the default it shipped with');
	}

	public function testKeepLeavesTheAuthorsTwoLineShape(): Void {
		Assert.equals(TWO_LINE, HxWriteFixture.triviaWrite(TWO_LINE, KEEP));
	}

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

	/** An explicit `"keep"` and an absent key must agree — that is what the KEEP-honouring reader buys. */
	public function testExplicitKeepAgreesWithTheAbsentKey(): Void {
		Assert.equals(HxWriteFixture.triviaWrite(TWO_LINE, KEEP), HxWriteFixture.triviaWrite(TWO_LINE, EXPLICIT_KEEP));
	}

	/** The knob reaches the value-`if` too (`HxIfExpr`), not only the statement form. */
	public function testTheValueIfCarriesItAsWell(): Void {
		final src: String = 'class F {\n\tfunction f(s:String):Int {\n\t\treturn if (s == \'\')\n\t\t\t0;\n'
			+ '\t\telse\n\t\t\tswitch s {\n\t\t\t\tcase _:\n\t\t\t\t\t1;\n\t\t\t}\n\t}\n}';
		final out: String = HxWriteFixture.triviaWrite(src, SAME);
		Assert.isTrue(out.indexOf('else switch s {') != -1, 'expected the value-if else to carry it too in: <$out>');
	}

	/** An `else if` chain that ENDS in an `else switch`: the chain links keep their own handler. */
	public function testAnElseIfChainEndingInElseSwitch(): Void {
		final src: String = 'class F {\n\tfunction f(s:String, b:Bool):Int {\n\t\tif (b)\n\t\t\treturn 0;\n'
			+ '\t\telse if (s == \'\')\n\t\t\treturn 1;\n\t\telse\n\t\t\tswitch s {\n\t\t\t\tcase _:\n\t\t\t\t\treturn 2;\n\t\t\t}\n\t}\n}';
		final out: String = HxWriteFixture.triviaWrite(src, SAME);
		Assert.isTrue(out.indexOf('else if (s == \'\')') != -1, 'the else-if link stays inline in: <$out>');
		Assert.isTrue(out.indexOf('else switch s {') != -1, 'the tail becomes `else switch` in: <$out>');
	}

	/**
	 * A comment between `else` and the `switch` DECLINES the glue, and the source survives BYTE FOR
	 * BYTE — indentation included.
	 *
	 * `buildElseSwitchCases` guards the `Same` arm on an empty leading-comment run. The mutation
	 * audit is why this asserts exact bytes rather than "the comment is still there": with the guard
	 * REMOVED the comment survives too, so a presence assertion cannot see the arm at all (measured —
	 * the arm ran green against the first version of this test). What the guard actually buys is the
	 * LAYOUT: without it the `switch` drops to the outer indent, one level shallower than the author
	 * wrote it, because the glue half-applies. Exact equality is the only assertion that separates
	 * the two.
	 */
	public function testACommentBetweenElseAndSwitchDeclinesTheGlue(): Void {
		final src: String = 'class F {\n\tfunction f(s:String):Int {\n\t\tif (s == \'\')\n\t\t\treturn 0;\n'
			+ '\t\telse\n\t\t\t// why\n\t\t\tswitch s {\n\t\t\t\tcase _:\n\t\t\t\t\treturn 1;\n\t\t\t}\n\t}\n}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, SAME));
	}

	public function testTheRewriteIsIdempotent(): Void {
		final once: String = HxWriteFixture.triviaWrite(TWO_LINE, SAME);
		Assert.equals(once, HxWriteFixture.triviaWrite(once, SAME));
	}

}

package unit;

import utest.Assert;
import utest.Test;

/**
 * D1 + D2 — the SEMANTIC complex-element counter and the fill-mode chunk policy it feeds.
 *
 * D1 gives the wrap cascade a `complexItemCount >= n` condition. An element counts as complex when
 * it is a `new`, a call, or a container literal (object / array) carrying one anywhere in its
 * subtree — so `[{ caption: tr('No'), … }, { caption: tr('Yes'), … }]` counts two even though every
 * element renders short. That is the point of asking the AST instead of a width proxy: an
 * `anyItemLength >= n` rule reproduces the same targets and then ALSO explodes `case [A, B]`
 * patterns and switch-subject arrays. A semantic counter reaches neither — except through the one
 * shape that looks like a call in pattern position, which `PATTERNS_SRC` pins.
 *
 * D2 is not a condition but a shape: under a `fillLine` / `fillLineWithLeadingBreak` argument list a
 * call-bearing container literal that would otherwise stay PACKED on a shared argument line takes a
 * line of its own instead, with the arguments before and after packed around it. Its scope is
 * exactly the element no existing glue speaks for:
 *  - element 0 is hugged by the head (`new Stack([` … `], w, 46)`);
 *  - a container that carries its OWN break has already opened the call, so the multi-arg-collection
 *    glue keeps it on the argument line (`super(W, H, …, [` … `], true, false, false)`) — declining
 *    there was measured over anyparse's own tree and made 21 files worse.
 * What is left is the container that FITS and would ride along in the fill packing, which is the
 * shape `TRAILING_SRC` and `MIDFIT_SRC` pin.
 *
 * Config: every assertion here is a width decision, so a compiled-default config would answer a
 * different question than the project these shapes come from. `CONFIG` is that project's
 * `hxformat.json` reduced to the sections these fixtures reach, verified to reproduce the full file
 * byte-for-byte on all of them. `CONFIG_NO_COND` is the same file with the `complexItemCount` rule
 * removed — which is what makes the D1 pairs discriminating (the counter is opt-in, so the same
 * source must stay flat there) and what proves D2 needs no configuration at all.
 */
@:nullSafety(Strict)
final class HxComplexItemWrapTest extends Test {

	/** The project's own `hxformat.json`, reduced to the sections these fixtures reach. */
	private static final CONFIG: String = '{"indentation":{"character":"tab","tabWidth":4},"wrapping":{"maxLineLength":140,"arrayWrap":{"defaultWra'
		+ 'p":"ignore","rules":[{"conditions":[{"cond":"complexItemCount >= n","value":2}],"type":"onePerLine"},{"c'
		+ 'onditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsM'
		+ 'axLineLength","value":1}],"type":"packedOrOnePerLine"}]},"objectLiteral":{"defaultWrap":"ignore","rules"'
		+ ':[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exc'
		+ 'eedsMaxLineLength","value":1}],"type":"packedOrOnePerLine"}]},"callParameter":{"defaultWrap":"fillLineWi'
		+ 'thLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"co'
		+ 'nditions":[{"cond":"itemCount <= n","value":1},{"cond":"totalItemLength <= n","value":100}],"type":"noWr'
		+ 'ap"}]}},"whitespace":{"bracesConfig":{"objectLiteralBraces":{"openingPolicy":"after","closingPolicy":"be'
		+ 'fore"}}},"sameLine":{"ifBody":"fitLine","functionBody":"fitLine","expressionIf":"next","expressionIfFit"'
		+ ':true,"comprehensionFor":"fitLine"},"emptyLines":{"classEmptyLines":{"beginType":1,"endType":1}}}';

	/** `CONFIG` with the `complexItemCount` rule dropped — the opt-in arm. */
	private static final CONFIG_NO_COND: String = '{"indentation":{"character":"tab","tabWidth":4},"wrapping":{"maxLineLength":140,"arrayWrap":{"defaultWra'
		+ 'p":"ignore","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"condit'
		+ 'ions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"packedOrOnePerLine"}]},"objectLiteral":{"defau'
		+ 'ltWrap":"ignore","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"c'
		+ 'onditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"packedOrOnePerLine"}]},"callParameter":{"'
		+ 'defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0'
		+ '}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1},{"cond":"totalItemLength <= n","v'
		+ 'alue":100}],"type":"noWrap"}]}},"whitespace":{"bracesConfig":{"objectLiteralBraces":{"openingPolicy":"af'
		+ 'ter","closingPolicy":"before"}}},"sameLine":{"ifBody":"fitLine","functionBody":"fitLine","expressionIf":'
		+ '"next","expressionIfFit":true,"comprehensionFor":"fitLine"},"emptyLines":{"classEmptyLines":{"beginType"' + ':1,"endType":1}}}';

	/** An argument list whose first argument is a `new` holding an array of three constructor calls. */
	private static final CTORS_SRC: String = 'class S1 {\n\n\tpublic function new(frameWidth:Float, frameHeight:Float) {\n\t\tsuper(new Stack([_frame,'
		+ ' new Gap(1, 6), _caption, new Gap(1, 6), new Frame(_clear, frameWidth, ICON_SIZE)], frameWidth, 46), fra'
		+ 'meWidth, frameHeight, PANEL_COLOR, 1, 3);\n\t}\n\n}';

	/** `CTORS_SRC` under `CONFIG`. */
	private static final CTORS_OUT: String = 'class S1 {\n\n\tpublic function new(frameWidth:Float, frameHeight:Float) {\n\t\tsuper(new Stack([\n\t\t'
		+ '\t_frame,\n\t\t\tnew Gap(1, 6),\n\t\t\t_caption,\n\t\t\tnew Gap(1, 6),\n\t\t\tnew Frame(_clear, frameWid'
		+ 'th, ICON_SIZE)\n\t\t], frameWidth, 46), frameWidth, frameHeight, PANEL_COLOR, 1, 3);\n\t}\n\n}';

	/** Two call-bearing object literals on a line that FITS, beside two literals holding no call. */
	private static final LITERALS_SRC: String = 'class S2 {\n\n\tprivate function actions():Array<ActionDescriptor> {\n\t\treturn [{ caption: tr(\'No\'),'
		+ ' action: NO, style: OutlineButton.OUTLINE }, { caption: tr(\'Yes\'), action: YES }];\n\t}\n\n\tprivate f'
		+ 'unction corners():Array<Corner> {\n\t\treturn [{ x: 1, y: 2 }, { x: 3, y: 4 }];\n\t}\n\n}';

	/** `LITERALS_SRC` under `CONFIG`. */
	private static final LITERALS_OUT: String = 'class S2 {\n\n\tprivate function actions():Array<ActionDescriptor> {\n\t\treturn [\n\t\t\t{ caption: tr('
		+ '\'No\'), action: NO, style: OutlineButton.OUTLINE },\n\t\t\t{ caption: tr(\'Yes\'), action: YES }\n\t\t]'
		+ ';\n\t}\n\n\tprivate function corners():Array<Corner> {\n\t\treturn [{ x: 1, y: 2 }, { x: 3, y: 4 }];\n\t' + '}\n\n}';

	/** An enum-constructor array pattern and a switch subject built from two calls. */
	private static final PATTERNS_SRC: String = 'class S3 {\n\n\tprivate function pick(v:Array<Option<Int>>):Int {\n\t\treturn switch v {\n\t\t\tcase [So'
		+ 'me(a), Some(b)]: a + b;\n\t\t\tcase _: 0;\n\t\t}\n\t}\n\n\tprivate function pickSubject(a:Int, b:Int):In'
		+ 't {\n\t\treturn switch [f(a), g(b)] {\n\t\t\tcase [1, 2]: 3;\n\t\t\tcase _: 0;\n\t\t}\n\t}\n\n}';

	/** `PATTERNS_SRC` under `CONFIG`. */
	private static final PATTERNS_OUT: String = 'class S3 {\n\n\tprivate function pick(v:Array<Option<Int>>):Int {\n\t\treturn switch v {\n\t\t\tcase [So'
		+ 'me(a), Some(b)]: a + b;\n\t\t\tcase _: 0;\n\t\t}\n\t}\n\n\tprivate function pickSubject(a:Int, b:Int):In'
		+ 't {\n\t\treturn switch [f(a), g(b)] {\n\t\t\tcase [1, 2]: 3;\n\t\t\tcase _: 0;\n\t\t}\n\t}\n\n}';

	/** A call whose LAST argument is an array holding one call-bearing object literal that FITS. */
	private static final TRAILING_SRC: String = 'class S4 {\n\n\tpublic function new() {\n\t\tsuper(536, 334, true, true, t(\'To gain the full editing ri'
		+ 'ghts here\'), null, [{ title: t(\'Close\', 76), action: \'shut\', width: 100 }]);\n\t}\n\n}';

	/** `TRAILING_SRC` under `CONFIG`. */
	private static final TRAILING_OUT: String = 'class S4 {\n\n\tpublic function new() {\n\t\tsuper(\n\t\t\t536, 334, true, true, t(\'To gain the full ed'
		+ 'iting rights here\'), null,\n\t\t\t[{ title: t(\'Close\', 76), action: \'shut\', width: 100 }]\n\t\t);\n' + '\t}\n\n}';

	/** A call with a call-bearing array in the middle whose OWN width breaks it, and three scalars after. */
	private static final MIDLIST_SRC: String = 'class S5 {\n\n\tpublic function new(source:ListSource) {\n\t\tsuper(WIDTH, HEIGHT, true, true, tr(\'Move'
		+ ' To\', 10084), null, [{ caption: tr(\'Cancel\', 73).toUpperCase(), action: CANCEL, style: OutlineButton.'
		+ 'OUTLINE }, { caption: tr(\'Move Here\', 9945).toUpperCase(), action: MOVE }], true, false, false);\n\t}' + '\n\n}';

	/** `MIDLIST_SRC` under `CONFIG`. */
	private static final MIDLIST_OUT: String = 'class S5 {\n\n\tpublic function new(source:ListSource) {\n\t\tsuper(WIDTH, HEIGHT, true, true, tr(\'Move'
		+ ' To\', 10084), null, [\n\t\t\t{ caption: tr(\'Cancel\', 73).toUpperCase(), action: CANCEL, style: Outlin'
		+ 'eButton.OUTLINE },\n\t\t\t{ caption: tr(\'Move Here\', 9945).toUpperCase(), action: MOVE }\n\t\t], true,'
		+ ' false, false);\n\t}\n\n}';

	/** The same middle position with a container that FITS — width alone would keep it packed. */
	private static final MIDFIT_SRC: String = 'class S6 {\n\n\tprivate function build():Void {\n\t\tregisterLayout(firstScalarValue, secondScalarValue,'
		+ ' [{ label: describe(\'mid\'), weight: 4 }], thirdScalarValue, fourthScalarValue, fifthValue);\n\t}\n\n}';

	/** `MIDFIT_SRC` under `CONFIG`. */
	private static final MIDFIT_OUT: String = 'class S6 {\n\n\tprivate function build():Void {\n\t\tregisterLayout(\n\t\t\tfirstScalarValue, secondScal'
		+ 'arValue,\n\t\t\t[{ label: describe(\'mid\'), weight: 4 }],\n\t\t\tthirdScalarValue, fourthScalarValue, f'
		+ 'ifthValue\n\t\t);\n\t}\n\n}';

	/** A call whose LAST argument is a MULTI-LINE call-bearing array — the fork hugs this one. */
	private static final LASTBIG_SRC: String = 'class S7 {\n\n\tstatic function main() {\n\t\treturn makeTimer(\'shell\', totalTime, [\n\t\t\tmakeTimer('
		+ '\'display call\', displayCallTime),\n\t\t\tmakeTimer(\'transmission\', transmissionTime),\n\t\t\tmakeTim'
		+ 'er(\'parsing\', parsingTime),\n\t\t\tmakeTimer(\'processing\', processingTime)\n\t\t]);\n\t}\n\n}';

	/** `LASTBIG_SRC` under `CONFIG`. */
	private static final LASTBIG_OUT: String = 'class S7 {\n\n\tstatic function main() {\n\t\treturn makeTimer(\'shell\', totalTime, [\n\t\t\tmakeTimer('
		+ '\'display call\', displayCallTime),\n\t\t\tmakeTimer(\'transmission\', transmissionTime),\n\t\t\tmakeTim'
		+ 'er(\'parsing\', parsingTime),\n\t\t\tmakeTimer(\'processing\', processingTime)\n\t\t]);\n\t}\n\n}';

	/** `CTORS_SRC` under `CONFIG_NO_COND`. */
	private static final CTORS_OUT_NO_COND: String = 'class S1 {\n\n\tpublic function new(frameWidth:Float, frameHeight:Float) {\n\t\tsuper(\n\t\t\tnew Stack('
		+ '[_frame, new Gap(1, 6), _caption, new Gap(1, 6), new Frame(_clear, frameWidth, ICON_SIZE)], frameWidth, '
		+ '46),\n\t\t\tframeWidth, frameHeight, PANEL_COLOR, 1, 3\n\t\t);\n\t}\n\n}';

	/** `LITERALS_SRC` under `CONFIG_NO_COND`. */
	private static final LITERALS_OUT_NO_COND: String = 'class S2 {\n\n\tprivate function actions():Array<ActionDescriptor> {\n\t\treturn [{ caption: tr(\'No\'),'
		+ ' action: NO, style: OutlineButton.OUTLINE }, { caption: tr(\'Yes\'), action: YES }];\n\t}\n\n\tprivate f'
		+ 'unction corners():Array<Corner> {\n\t\treturn [{ x: 1, y: 2 }, { x: 3, y: 4 }];\n\t}\n\n}';

	/** `TRAILING_SRC` under `CONFIG_NO_COND`. */
	private static final TRAILING_OUT_NO_COND: String = 'class S4 {\n\n\tpublic function new() {\n\t\tsuper(\n\t\t\t536, 334, true, true, t(\'To gain the full ed'
		+ 'iting rights here\'), null,\n\t\t\t[{ title: t(\'Close\', 76), action: \'shut\', width: 100 }]\n\t\t);\n' + '\t}\n\n}';

	/** `MIDLIST_SRC` under `CONFIG_NO_COND`. */
	private static final MIDLIST_OUT_NO_COND: String = 'class S5 {\n\n\tpublic function new(source:ListSource) {\n\t\tsuper(\n\t\t\tWIDTH, HEIGHT, true, true, t'
		+ 'r(\'Move To\', 10084), null,\n\t\t\t[\n\t\t\t\t{ caption: tr(\'Cancel\', 73).toUpperCase(), action: CANC'
		+ 'EL, style: OutlineButton.OUTLINE },\n\t\t\t\t{ caption: tr(\'Move Here\', 9945).toUpperCase(), action: M'
		+ 'OVE }\n\t\t\t],\n\t\t\ttrue, false, false\n\t\t);\n\t}\n\n}';

	/** `MIDFIT_SRC` under `CONFIG_NO_COND`. */
	private static final MIDFIT_OUT_NO_COND: String = 'class S6 {\n\n\tprivate function build():Void {\n\t\tregisterLayout(\n\t\t\tfirstScalarValue, secondScal'
		+ 'arValue,\n\t\t\t[{ label: describe(\'mid\'), weight: 4 }],\n\t\t\tthirdScalarValue, fourthScalarValue, f'
		+ 'ifthValue\n\t\t);\n\t}\n\n}';

	public function new(): Void {
		super();
	}

	/**
	 * Three `new` elements send the array one per line — AND the enclosing `new Stack([` stays hugged
	 * to its head. Both halves are in one asserted string on purpose.
	 */
	public function testConstructorElementsBreakWhileTheHeadKeepsTheHug(): Void {
		Assert.equals(CTORS_OUT, write(CTORS_SRC, CONFIG));
	}

	/** Same source with the condition absent: flat, exactly as before the slice. The counter is opt-in. */
	public function testConstructorElementsStayFlatWithoutTheCondition(): Void {
		Assert.equals(CTORS_OUT_NO_COND, write(CTORS_SRC, CONFIG_NO_COND));
	}

	/**
	 * The discriminator against a width proxy: the two call-bearing literals break though their line
	 * FITS, while `[{ x: 1, y: 2 }, { x: 3, y: 4 }]` — containers with no call — stays flat in the same
	 * file. No width rule can produce that pair.
	 */
	public function testCallBearingLiteralsBreakAndCallFreeOnesDoNot(): Void {
		Assert.equals(LITERALS_OUT, write(LITERALS_SRC, CONFIG));
	}

	/** Without the condition both literal arrays stay flat. */
	public function testLiteralsStayFlatWithoutTheCondition(): Void {
		Assert.equals(LITERALS_OUT_NO_COND, write(LITERALS_SRC, CONFIG_NO_COND));
	}

	/**
	 * An enum-constructor pattern parses as a `Call` and a switch subject is a genuine array of calls,
	 * so both are counted and exploded one element per line unless suppressed. Measured before the
	 * gate existed; this fixture goes red if `@:fmt(suppressComplexItems)` is removed from
	 * `HxCasePattern.expr` / `HxSwitchStmt(Bare).expr`. It does NOT discriminate against the pre-slice
	 * writer — nothing counted anything there — which is exactly why it is worth keeping.
	 */
	public function testCasePatternsAndSwitchSubjectsAreNotCounted(): Void {
		Assert.equals(PATTERNS_OUT, write(PATTERNS_SRC, CONFIG));
	}

	/**
	 * D2 with NO condition configured: the trailing call-bearing array leaves the packed argument line
	 * and takes one of its own. Pre-slice all seven arguments shared one 138-column line.
	 */
	public function testTrailingContainerTakesItsOwnLineWithoutAnyCondition(): Void {
		Assert.equals(TRAILING_OUT_NO_COND, write(TRAILING_SRC, CONFIG_NO_COND));
	}

	/** The same shape under the full config — the condition does not disturb D2. */
	public function testTrailingContainerUnaffectedByTheCondition(): Void {
		Assert.equals(TRAILING_OUT, write(TRAILING_SRC, CONFIG));
	}

	/**
	 * A FITTING container in the MIDDLE splits the list in three: the arguments before it pack, it
	 * takes its own line, the arguments after it pack again. Nothing about its width asks for that —
	 * the split comes from the classification alone, which is why the two configs agree here.
	 */
	public function testMidListFittingContainerSplitsTheArgumentsAroundIt(): Void {
		Assert.equals(MIDFIT_OUT_NO_COND, write(MIDFIT_SRC, CONFIG_NO_COND));
		Assert.equals(MIDFIT_OUT, write(MIDFIT_SRC, CONFIG));
	}

	/**
	 * The boundary of that policy: a container whose own elements break keeps the multi-arg-collection
	 * glue and stays on the argument line, in the middle of the list as at its end. The two configs
	 * DIFFER here — the counter turns the array's width-driven break into a forced one, which is what
	 * lets the glue accept it — so this pins both sides.
	 */
	public function testMidListBreakingContainerKeepsTheGlue(): Void {
		Assert.equals(MIDLIST_OUT_NO_COND, write(MIDLIST_SRC, CONFIG_NO_COND));
		Assert.equals(MIDLIST_OUT, write(MIDLIST_SRC, CONFIG));
	}

	/**
	 * Same boundary at the END of the list, and the shape the fork's
	 * `wrapping/issue_466_array_wrapping_regression` fixture pins: the call closes on the bracket
	 * line rather than giving the array a further line of its own.
	 */
	public function testTrailingMultilineContainerKeepsTheGlue(): Void {
		Assert.equals(LASTBIG_OUT, write(LASTBIG_SRC, CONFIG));
	}

	/** Every produced layout is a fixed point — a second write reproduces it. */
	public function testLayoutsAreIdempotent(): Void {
		Assert.equals(CTORS_OUT, write(CTORS_OUT, CONFIG));
		Assert.equals(LITERALS_OUT, write(LITERALS_OUT, CONFIG));
		Assert.equals(TRAILING_OUT, write(TRAILING_OUT, CONFIG));
		Assert.equals(MIDLIST_OUT, write(MIDLIST_OUT, CONFIG));
		Assert.equals(MIDFIT_OUT, write(MIDFIT_OUT, CONFIG));
		Assert.equals(LASTBIG_OUT, write(LASTBIG_OUT, CONFIG));
	}

	private inline function write(src: String, config: String): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

}

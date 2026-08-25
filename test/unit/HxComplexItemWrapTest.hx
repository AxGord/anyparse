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
 *
 * One later fixture is not a D1/D2 shape at all: `THREE_CALLS_*` pins that the count also
 * reaches the CONTINUATION INDENT, not just the wrap mode. It needs a config of its own
 * because it has to pair `complexItemCount >= n` with a `defaultAdditionalIndent`, and no
 * shipped config does.
 */
@:nullSafety(Strict)
final class HxComplexItemWrapTest extends Test {

	/** The project's own `hxformat.json`, reduced to the sections these fixtures reach. */
	private static final CONFIG: String = '{"indentation":{"character":"tab","tabWidth":4},'
		+ '"wrapping":{"maxLineLength":140,"arrayWrap":{"defaultWrap":"ignore","rules":[{"conditions":[{"cond":"complexItemCount >= '
		+ 'n","value":2}],"type":"onePerLine"},{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{'
		+ '"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"packedOrOnePerLine"}]},'
		+ '"objectLiteral":{"defaultWrap":"ignore","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{'
		+ '"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"packedOrOnePerLine"}]},'
		+ '"callParameter":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],'
		+ '"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1},{"cond":"totalItemLength <= n","value":100}],"type":"noWr'
		+ 'ap"}]}},"whitespace":{"bracesConfig":{"objectLiteralBraces":{"openingPolicy":"after","closingPolicy":"before"}}},'
		+ '"sameLine":{"ifBody":"fitLine","functionBody":"fitLine","expressionIf":"next","expressionIfFit":true,'
		+ '"comprehensionFor":"fitLine"},"emptyLines":{"classEmptyLines":{"beginType":1,"endType":1}}}';

	/** `CONFIG` with the `complexItemCount` rule dropped — the opt-in arm. */
	private static final CONFIG_NO_COND: String = '{"indentation":{"character":"tab","tabWidth":4},'
		+ '"wrapping":{"maxLineLength":140,"arrayWrap":{"defaultWrap":"ignore","rules":[{"conditions":[{"cond":"exceedsMaxLineLength",'
		+ '"value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"packedOrOnePerLine"}]},'
		+ '"objectLiteral":{"defaultWrap":"ignore","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"c'
		+ 'onditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"packedOrOnePerLine"}]},'
		+ '"callParameter":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0'
		+ '}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1},{"cond":"totalItemLength <= n","value":100}],'
		+ '"type":"noWrap"}]}},"whitespace":{"bracesConfig":{"objectLiteralBraces":{"openingPolicy":"after","closingPolicy":"before"}}},'
		+ '"sameLine":{"ifBody":"fitLine","functionBody":"fitLine","expressionIf":"next","expressionIfFit":true,'
		+ '"comprehensionFor":"fitLine"},"emptyLines":{"classEmptyLines":{"beginType":1,"endType":1}}}';

	/**
	 * A cascade that pairs `complexItemCount >= n` with a `defaultAdditionalIndent`, so the
	 * continuation INDENT depends on the same cascade answer the wrap MODE does. The only
	 * config here that is not a reduction of a real project's `hxformat.json` — it exists to
	 * put those two knobs in one cascade, which no shipped config does.
	 */
	private static final THREE_CALLS_CONFIG: String = '{"indentation":{"character":"tab","tabWidth":4},'
		+ '"wrapping":{"maxLineLength":140,"arrayWrap":{"defaultWrap":"noWrap","defaultAdditionalIndent":1,'
		+ '"rules":[{"conditions":[{"cond":"complexItemCount >= n","value":2}],"type":"onePerLine"}]}}}';

	/** An argument list whose first argument is a `new` holding an array of three constructor calls. */
	private static final CTORS_SRC: String = 'class S1 {\n\n\tpublic function new(frameWidth:Float, frameHeight:Float) {\n'
		+ '\t\tsuper(new Stack([_frame, new Gap(1, 6), _caption, new Gap(1, 6), new Frame(_clear, frameWidth, ICON_SIZE)], frameWidth, '
		+ '46), frameWidth, frameHeight, PANEL_COLOR, 1, 3);\n\t}\n\n}';

	/** `CTORS_SRC` under `CONFIG`. */
	private static final CTORS_OUT: String = 'class S1 {\n\n\tpublic function new(frameWidth:Float, frameHeight:Float) {\n\t\tsuper(new Stack([\n\t\t'
		+ '\t_frame,\n\t\t\tnew Gap(1, 6),\n\t\t\t_caption,\n\t\t\tnew Gap(1, 6),\n\t\t\tnew Frame(_clear, frameWid'
		+ 'th, ICON_SIZE)\n\t\t], frameWidth, 46), frameWidth, frameHeight, PANEL_COLOR, 1, 3);\n\t}\n\n}';

	/** Two call-bearing object literals on a line that FITS, beside two literals holding no call. */
	private static final LITERALS_SRC: String = 'class S2 {\n\n\tprivate function actions():Array<ActionDescriptor> {\n'
		+ '\t\treturn [{ caption: tr(\'No\'), action: NO, style: OutlineButton.OUTLINE }, { caption: tr(\'Yes\'), action: YES }];\n\t}\n\n'
		+ '\tprivate function corners():Array<Corner> {\n\t\treturn [{ x: 1, y: 2 }, { x: 3, y: 4 }];\n\t}\n\n}';

	/** `LITERALS_SRC` under `CONFIG`. */
	private static final LITERALS_OUT: String = 'class S2 {\n\n\tprivate function actions():Array<ActionDescriptor> {\n\t\treturn [\n'
		+ '\t\t\t{ caption: tr(\'No\'), action: NO, style: OutlineButton.OUTLINE },\n\t\t\t{ caption: tr(\'Yes\'), action: YES }\n\t\t];\n'
		+ '\t}\n\n\tprivate function corners():Array<Corner> {\n\t\treturn [{ x: 1, y: 2 }, { x: 3, y: 4 }];\n\t}\n\n}';

	/** An enum-constructor array pattern and a switch subject built from two calls. */
	private static final PATTERNS_SRC: String = 'class S3 {\n\n\tprivate function pick(v:Array<Option<Int>>):Int {\n\t\treturn switch v {\n'
		+ '\t\t\tcase [Some(a), Some(b)]: a + b;\n\t\t\tcase _: 0;\n\t\t}\n\t}\n\n\tprivate function pickSubject(a:Int, b:Int):Int {\n'
		+ '\t\treturn switch [f(a), g(b)] {\n\t\t\tcase [1, 2]: 3;\n\t\t\tcase _: 0;\n\t\t}\n\t}\n\n}';

	/** `PATTERNS_SRC` under `CONFIG`. */
	private static final PATTERNS_OUT: String = 'class S3 {\n\n\tprivate function pick(v:Array<Option<Int>>):Int {\n\t\treturn switch v {\n'
		+ '\t\t\tcase [Some(a), Some(b)]: a + b;\n\t\t\tcase _: 0;\n\t\t}\n\t}\n\n\tprivate function pickSubject(a:Int, b:Int):Int {\n'
		+ '\t\treturn switch [f(a), g(b)] {\n\t\t\tcase [1, 2]: 3;\n\t\t\tcase _: 0;\n\t\t}\n\t}\n\n}';

	/** A call whose LAST argument is an array holding one call-bearing object literal that FITS. */
	private static final TRAILING_SRC: String = 'class S4 {\n\n\tpublic function new() {\n'
		+ '\t\tsuper(536, 334, true, true, t(\'To gain the full editing rights here\'), null, ['
		+ '{ title: t(\'Close\', 76), action: \'shut\', width: 100 }]);\n\t}\n\n}';

	/** `TRAILING_SRC` under `CONFIG`. */
	private static final TRAILING_OUT: String = 'class S4 {\n\n\tpublic function new() {\n\t\tsuper(\n'
		+ '\t\t\t536, 334, true, true, t(\'To gain the full editing rights here\'), null,\n'
		+ '\t\t\t[{ title: t(\'Close\', 76), action: \'shut\', width: 100 }]\n\t\t);\n\t}\n\n}';

	/** A call with a call-bearing array in the middle whose OWN width breaks it, and three scalars after. */
	private static final MIDLIST_SRC: String = 'class S5 {\n\n\tpublic function new(source:ListSource) {\n\t\tsuper(WIDTH, HEIGHT, true, '
		+ 'true, tr(\'Move To\', 10084), null, [{ caption: tr(\'Cancel\', 73).toUpperCase(), '
		+ 'action: CANCEL, style: OutlineButton.OUTLINE }, { caption: tr(\'Move Here\', '
		+ '9945).toUpperCase(), action: MOVE }], true, false, false);\n\t}\n\n}';

	/** `MIDLIST_SRC` under `CONFIG`. */
	private static final MIDLIST_OUT: String = 'class S5 {\n\n\tpublic function new(source:ListSource) {\n\t\tsuper(WIDTH, HEIGHT, true, '
		+ 'true, tr(\'Move To\', 10084), null, [\n\t\t\t{ caption: tr(\'Cancel\', 73).toUpperCase(), '
		+ 'action: CANCEL, style: OutlineButton.OUTLINE },\n\t\t\t{ caption: tr(\'Move Here\', '
		+ '9945).toUpperCase(), action: MOVE }\n\t\t], true, false, false);\n\t}\n\n}';

	/** The same middle position with a container that FITS — width alone would keep it packed. */
	private static final MIDFIT_SRC: String = 'class S6 {\n\n\tprivate function build():Void {\n'
		+ '\t\tregisterLayout(firstScalarValue, secondScalarValue, [{ label: describe(\'mid\'), '
		+ 'weight: 4 }], thirdScalarValue, fourthScalarValue, fifthValue);\n\t}\n\n}';

	/** `MIDFIT_SRC` under `CONFIG`. */
	private static final MIDFIT_OUT: String = 'class S6 {\n\n\tprivate function build():Void {\n\t\tregisterLayout(\n\t\t\tfirstScalarValue, secondScal'
		+ 'arValue,\n\t\t\t[{ label: describe(\'mid\'), weight: 4 }],\n\t\t\tthirdScalarValue, fourthScalarValue, f'
		+ 'ifthValue\n\t\t);\n\t}\n\n}';

	/** A call whose LAST argument is a MULTI-LINE call-bearing array — the fork hugs this one. */
	private static final LASTBIG_SRC: String = 'class S7 {\n\n\tstatic function main() {\n\t\treturn makeTimer(\'shell\', totalTime, [\n'
		+ '\t\t\tmakeTimer(\'display call\', displayCallTime),\n\t\t\tmakeTimer(\'transmission\', transmissionTime),\n'
		+ '\t\t\tmakeTimer(\'parsing\', parsingTime),\n\t\t\tmakeTimer(\'processing\', processingTime)\n\t\t]);\n\t}\n\n}';

	/** `LASTBIG_SRC` under `CONFIG`. */
	private static final LASTBIG_OUT: String = 'class S7 {\n\n\tstatic function main() {\n\t\treturn makeTimer(\'shell\', totalTime, [\n'
		+ '\t\t\tmakeTimer(\'display call\', displayCallTime),\n\t\t\tmakeTimer(\'transmission\', transmissionTime),\n'
		+ '\t\t\tmakeTimer(\'parsing\', parsingTime),\n\t\t\tmakeTimer(\'processing\', processingTime)\n\t\t]);\n\t}\n\n}';

	/** Three calls on ONE source line — the condition fires, and nothing else in the cascade breaks it. */
	private static final THREE_CALLS_SRC: String = 'class S8 {\n\tstatic var a = [f(1), g(2), h(3)];\n}';

	/** `INDENT_SRC` under `INDENT_CONFIG` — one `defaultAdditionalIndent` unit, not two. */
	private static final THREE_CALLS_OUT: String = 'class S8 {\n\tstatic var a = [\n\t\tf(1),\n\t\tg(2),\n\t\th(3)\n\t];\n}';

	/** `CTORS_SRC` under `CONFIG_NO_COND`. */
	private static final CTORS_OUT_NO_COND: String = 'class S1 {\n\n\tpublic function new(frameWidth:Float, frameHeight:Float) {\n'
		+ '\t\tsuper(\n\t\t\tnew Stack([_frame, new Gap(1, 6), _caption, new Gap(1, 6), new '
		+ 'Frame(_clear, frameWidth, ICON_SIZE)], frameWidth, '
		+ '46),\n\t\t\tframeWidth, frameHeight, PANEL_COLOR, 1, 3\n\t\t);\n\t}\n\n}';

	/** `LITERALS_SRC` under `CONFIG_NO_COND`. */
	private static final LITERALS_OUT_NO_COND: String = 'class S2 {\n\n\tprivate function actions():Array<ActionDescriptor> {\n'
		+ '\t\treturn [{ caption: tr(\'No\'), action: NO, style: OutlineButton.OUTLINE }, { caption: tr(\'Yes\'), action: YES }];\n\t}\n\n'
		+ '\tprivate function corners():Array<Corner> {\n\t\treturn [{ x: 1, y: 2 }, { x: 3, y: 4 }];\n\t}\n\n}';

	/** `TRAILING_SRC` under `CONFIG_NO_COND`. */
	private static final TRAILING_OUT_NO_COND: String = 'class S4 {\n\n\tpublic function new() {\n\t\tsuper(\n\t\t\t536, 334, true, '
		+ 'true, t(\'To gain the full editing rights here\'), null,\n\t\t\t[{ title: '
		+ 't(\'Close\', 76), action: \'shut\', width: 100 }]\n\t\t);\n\t}\n\n}';

	/** `MIDLIST_SRC` under `CONFIG_NO_COND`. */
	private static final MIDLIST_OUT_NO_COND: String = 'class S5 {\n\n\tpublic function new(source:ListSource) {\n\t\tsuper(\n'
		+ '\t\t\tWIDTH, HEIGHT, true, true, tr(\'Move To\', 10084), null,\n\t\t\t[\n\t\t\t\t{ caption: tr(\'Cancel\', 73).toUpperCase(), '
		+ 'action: CANCEL, style: OutlineButton.OUTLINE },\n\t\t\t\t{ caption: tr(\'Move Here\', 9945).toUpperCase(), '
		+ 'action: MOVE }\n\t\t\t],\n\t\t\ttrue, false, false\n\t\t);\n\t}\n\n}';

	/** `MIDFIT_SRC` under `CONFIG_NO_COND`. */
	private static final MIDFIT_OUT_NO_COND: String = 'class S6 {\n\n\tprivate function build():Void {\n\t\tregisterLayout(\n'
		+ '\t\t\tfirstScalarValue, secondScalarValue,\n\t\t\t[{ label: describe(\'mid\'), weight: 4 }],\n'
		+ '\t\t\tthirdScalarValue, fourthScalarValue, fifthValue\n\t\t);\n\t}\n\n}';

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

	/**
	 * The wrap MODE and the continuation INDENT have to come out of the same cascade answer.
	 * `continuationCols` re-runs the cascade to learn whether it forces a break, and it used to
	 * hand that probe a hardcoded `complexItemCount` of 0 — so a `complexItemCount >= n` rule
	 * selected `onePerLine` for the mode and then computed the indent as if the list held no
	 * complex items, landing every element one unit deeper than the cascade's own
	 * `defaultAdditionalIndent`.
	 *
	 * ONE write pass over a ONE-LINE source is what discriminates, and both halves of that
	 * matter. Measured on the pre-fix writer with this exact config: pass 1 over the one-line
	 * source gives three tabs, pass 2 over pass 1's output gives two, pass 3 reproduces pass 2.
	 * So `fmt` reported the shape as "needed 2 rewrites to reach its fixed point" rather than as
	 * wrong output — which is why no corpus run and no `fmt --list` gate ever saw it, and why a
	 * fixture seeded with an already-broken list would prove nothing.
	 *
	 * What makes pass 2 land on the right indent is NOT source-multiline keeping: with the rule
	 * removed, the already-broken list collapses back to one line, so nothing here is preserving
	 * the source layout. The actual second-pass route is unidentified — recorded as measured
	 * rather than guessed. Its consequence for this file: the `THREE_CALLS_OUT` line in
	 * `testLayoutsAreIdempotent` is vacuous with respect to THIS fix (the pre-fix writer
	 * satisfies it too, verified — reverting turns exactly this one test red, not two). It pins
	 * the fixed point, which is still worth pinning.
	 */
	public function testComplexItemCountReachesTheContinuationIndent(): Void {
		Assert.equals(THREE_CALLS_OUT, write(THREE_CALLS_SRC, THREE_CALLS_CONFIG));
	}

	/** Every produced layout is a fixed point — a second write reproduces it. */
	public function testLayoutsAreIdempotent(): Void {
		Assert.equals(CTORS_OUT, write(CTORS_OUT, CONFIG));
		Assert.equals(LITERALS_OUT, write(LITERALS_OUT, CONFIG));
		Assert.equals(TRAILING_OUT, write(TRAILING_OUT, CONFIG));
		Assert.equals(MIDLIST_OUT, write(MIDLIST_OUT, CONFIG));
		Assert.equals(MIDFIT_OUT, write(MIDFIT_OUT, CONFIG));
		Assert.equals(LASTBIG_OUT, write(LASTBIG_OUT, CONFIG));
		Assert.equals(THREE_CALLS_OUT, write(THREE_CALLS_OUT, THREE_CALLS_CONFIG));
	}

	private inline function write(src: String, config: String): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

}

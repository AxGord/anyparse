package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * ω-cond-expr-fit: `sameLine.conditionalExprFit` breaks an expression-scope `#if … #end` region at its directive
 * seams — the way a regular `if / else if / else` chain breaks — when the GLUED form does not fit the line. Off
 * (the default), the writer keeps the source-driven layout: glued seams stay glued and only the branch VALUES
 * wrap inside themselves, burying every `#elseif` mid-line (the shape
 * `HxCondExprValueFixpointSliceTest.BROKEN_RETURN` pins).
 *
 * The decision is one `GroupWithRestProbe` around the whole `#if … #end` emission, so every seam answers
 * TOGETHER: a fitting region keeps its spaces (`Line(' ')` renders flat), an over-wide one drops every directive
 * onto its own line at the statement indent with each branch value one step deeper — and a source hardline at ANY
 * seam refuses the flat measure, so a partially broken region normalises to the full ladder instead of keeping a
 * mixed shape.
 *
 * Every over-wide fixture is asserted on both knob states off one config pair differing in nothing else, so a
 * diff is attributable to the knob rather than to a second config key.
 */
@:nullSafety(Strict)
final class HxConditionalExprFitSliceTest extends Test {

	/** Minimal config with the knob ON. */
	private static final FIT_ON: String = config(true);

	/** The same config with the knob OFF — the source-driven layout the fixpoint suite pins. */
	private static final FIT_OFF: String = config(false);

	/** Over-wide conditional value with every seam glued (the `cond-assign-merge --fix` output shape). */
	private static final GLUED: String = 'class Min {\n\tstatic function retArm():RegisteredDeviceTypeId {\n'
		+ '\t\treturn #if ios DEVICETYPE_IPAD #elseif android ChromebookUtils.isChromebook() ? DEVICETYPE_WINDOWSPC : DEVICETYPE_TABLET '
		+ '#elseif macos DEVICETYPE_MACOSXPC #elseif (windows || linux) DEVICETYPE_WINDOWSPC #else DEVICETYPE_WEB #end;\n\t}\n}';

	/**
	 * The knob-off answer for `GLUED`: seams stay glued, the over-wide android branch's ternary breaks inside —
	 * `HxCondExprValueFixpointSliceTest.BROKEN_RETURN` verbatim.
	 */
	private static final GLUED_TERNARY_BROKEN: String = 'class Min {\n\tstatic function retArm():RegisteredDeviceTypeId {\n'
		+ '\t\treturn #if ios DEVICETYPE_IPAD #elseif android ChromebookUtils.isChromebook()\n'
		+ '\t\t\t? DEVICETYPE_WINDOWSPC\n\t\t\t: DEVICETYPE_TABLET #elseif macos DEVICETYPE_MACOSXPC '
		+ '#elseif (windows || linux) DEVICETYPE_WINDOWSPC #else DEVICETYPE_WEB #end;\n\t}\n}';

	/** The knob-on answer: directives at the statement indent, each branch value one indent step deeper. */
	private static final LADDER: String = 'class Min {\n\tstatic function retArm():RegisteredDeviceTypeId {\n'
		+ '\t\treturn #if ios\n\t\t\tDEVICETYPE_IPAD\n'
		+ '\t\t#elseif android\n\t\t\tChromebookUtils.isChromebook() ? DEVICETYPE_WINDOWSPC : DEVICETYPE_TABLET\n'
		+ '\t\t#elseif macos\n\t\t\tDEVICETYPE_MACOSXPC\n' + '\t\t#elseif (windows || linux)\n\t\t\tDEVICETYPE_WINDOWSPC\n'
		+ '\t\t#else\n\t\t\tDEVICETYPE_WEB\n' + '\t\t#end;\n\t}\n}';

	/** A conditional value that fits its line — the knob must leave it alone. */
	private static final SHORT_FLAT: String =
		'class Min {\n\tstatic function f():Void {\n\t\tv = #if a XXXX #elseif b YYYY #else WWWW #end;\n\t}\n}';

	/**
	 * A FITTING region whose only source break sits before the first `#elseif` — the hardline-refusal path: the
	 * seam hardline alone makes the group unfittable, so the knob normalises the region to the full ladder even
	 * though width never forced it. Knob off, the pre-existing source-driven layout is the expected fixed point
	 * (the `#else` seam follows the first clause's `newlineBefore`, the `#end` stays glued).
	 */
	private static final MIXED_SEAM: String =
		'class Min {\n\tstatic function f():Void {\n\t\tv = #if a XXXX\n\t\t#elseif b YYYY #else WWWW #end;\n\t}\n}';

	/** Its knob-on ladder. */
	private static final MIXED_SEAM_LADDER: String = 'class Min {\n\tstatic function f():Void {\n'
		+ '\t\tv = #if a\n\t\t\tXXXX\n\t\t#elseif b\n\t\t\tYYYY\n\t\t#else\n\t\t\tWWWW\n\t\t#end;\n\t}\n}';

	/** Its knob-off fixed point. */
	private static final MIXED_SEAM_SOURCE: String =
		'class Min {\n\tstatic function f():Void {\n\t\tv = #if a XXXX\n\t\t#elseif b YYYY\n\t\t#else WWWW #end;\n\t}\n}';

	/** An over-wide `#if`/`#else` pair with NO `#elseif` clause — the seam signals ride a different slot pair. */
	private static final NO_ELSEIF_GLUED: String = 'class Min {\n\tstatic function g():Void {\n'
		+ '\t\tv = #if debug PRIMARY_FALLBACK_CONFIGURATION_VALUE_FOR_THE_DEVELOPMENT_TARGET'
		+ ' #else SECONDARY_FALLBACK_CONFIGURATION_VALUE_FOR_THE_RELEASE_TARGET #end;\n\t}\n}';

	/** Its ladder. */
	private static final NO_ELSEIF_LADDER: String = 'class Min {\n\tstatic function g():Void {\n\t\tv = #if debug\n'
		+ '\t\t\tPRIMARY_FALLBACK_CONFIGURATION_VALUE_FOR_THE_DEVELOPMENT_TARGET\n\t\t#else\n'
		+ '\t\t\tSECONDARY_FALLBACK_CONFIGURATION_VALUE_FOR_THE_RELEASE_TARGET\n\t\t#end;\n\t}\n}';

	public function new(): Void {
		super();
	}

	/** The reported shape: an over-wide glued region drops every directive onto its own line. */
	public function testOverwideGluedBreaksAtDirectiveSeams(): Void {
		Assert.equals(LADDER, triviaWrite(GLUED, FIT_ON));
	}

	/** The ladder is a fixed point — a second write neither re-glues it nor re-breaks it. */
	public function testLadderIsAFixedPoint(): Void {
		Assert.equals(LADDER, triviaWrite(LADDER, FIT_ON));
	}

	/** A partially broken region (glued seams, value broken inside) normalises to the full ladder. */
	public function testPartiallyBrokenNormalisesToTheLadder(): Void {
		Assert.equals(LADDER, triviaWrite(GLUED_TERNARY_BROKEN, FIT_ON));
	}

	/** Knob OFF keeps the source-driven layout — the discriminator against the change leaking into the default. */
	public function testKnobOffKeepsTheGluedLayout(): Void {
		Assert.equals(GLUED_TERNARY_BROKEN, triviaWrite(GLUED, FIT_OFF));
	}

	/** Knob OFF still preserves a source ladder byte-identically (the pre-existing source-driven path). */
	public function testKnobOffPreservesASourceLadder(): Void {
		Assert.equals(LADDER, triviaWrite(LADDER, FIT_OFF));
	}

	/** A region that fits its line keeps its glued shape under either knob state. */
	public function testShortConditionalStaysFlat(): Void {
		Assert.equals(SHORT_FLAT, triviaWrite(SHORT_FLAT, FIT_ON));
		Assert.equals(SHORT_FLAT, triviaWrite(SHORT_FLAT, FIT_OFF));
	}

	/** The `#if`/`#else`-only shape (empty `elseifs` Star) breaks at both of its seams too, and only under the knob. */
	public function testNoElseifRegionBreaksAtBothSeams(): Void {
		Assert.equals(NO_ELSEIF_LADDER, triviaWrite(NO_ELSEIF_GLUED, FIT_ON));
		Assert.equals(NO_ELSEIF_LADDER, triviaWrite(NO_ELSEIF_LADDER, FIT_ON));
		Assert.equals(NO_ELSEIF_GLUED, triviaWrite(NO_ELSEIF_GLUED, FIT_OFF));
	}

	/**
	 * The hardline-refusal path, isolated from width: a FITTING region with one seam hardline normalises to the
	 * full ladder under the knob — the source hardline refuses the flat measure, and every soft seam breaks with
	 * it. Knob off pins the pre-existing source-driven fixed point of the same input.
	 */
	public function testSeamHardlineAloneForcesTheFullLadder(): Void {
		Assert.equals(MIXED_SEAM_LADDER, triviaWrite(MIXED_SEAM, FIT_ON));
		Assert.equals(MIXED_SEAM_LADDER, triviaWrite(MIXED_SEAM_LADDER, FIT_ON));
		Assert.equals(MIXED_SEAM_SOURCE, triviaWrite(MIXED_SEAM, FIT_OFF));
	}

	private inline function triviaWrite(src: String, config: String): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

	/** Minimal config parameterised on the one key under test. */
	private static function config(fit: Bool): String {
		return '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140},'
			+ ' "sameLine": {"conditionalExprFit": $fit}}';
	}

}

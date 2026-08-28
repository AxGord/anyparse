package unit;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * ω-measured-multiline-decl — a top-level declaration that RENDERS across
 * more than one line is separated from its neighbours by a blank line, even
 * when its SHAPE says otherwise.
 *
 * The structural predicate behind `afterMultilineDecl` / `beforeMultilineDecl`
 * answers from the payload: a class is multi-line iff it declares members. An
 * empty-bodied `class C extends B implements … {}` whose heritage clauses wrap
 * is single-line by that rule and three lines on the page, so the pair around
 * it lost its blank. Fork `MarkEmptyLines.getTypeInfo` asks `isSameLine` over
 * the whitespace `MarkWrapping` has already committed — a rendering property —
 * which is what the measured channel reproduces.
 *
 * The four pins were verified RED against the base commit `4cae819a`: each
 * gap came back with no blank line. Four controls are green at base BY
 * CONSTRUCTION (they assert the gap does NOT change) and each names the
 * mutation that flips it — see their own doc comments. The ninth method,
 * `testWriterIsItsOwnFixedPoint`, is neither: it is a forward guard on the
 * new output.
 */
@:nullSafety(Strict)
class HxMeasuredMultilineDeclBlankSliceTest extends Test {

	/**
	 * A 164-column class header: over `maxLineLength`, so it measures
	 * multi-line, and over the `implementsExtends` rule's own threshold, so
	 * under `CFG` it actually wraps. Its body is empty, so the STRUCTURAL
	 * predicate calls it single-line — that disagreement is the whole slice.
	 * Under `NOWRAP` the same header has nowhere to break and renders as one
	 * over-wide line, which is the other half of the question.
	 */
	private static final LONG: String = 'class LongerName extends LongBaseClass implements ILongFormInterface implements ILongFormInterface1 '
		+ 'implements ILongFormInterface2 implements ILongFormInterface3 {}';

	/** Tabs, 140 columns, and an `implementsExtends` rule that wraps a header at that width. */
	private static final CFG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, '
		+ '"implementsExtends": {"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": "lineLength >= n", "value": 140}], '
		+ '"type": "onePerLineAfterFirst"}]}}}';

	/**
	 * `CFG` with the heritage cascade cleared — `defaultWrap` alone is a
	 * no-op, the empty `rules` list is what removes the wrap. Same 140-column
	 * limit, so the same header is over-wide with nowhere to spend a break.
	 */
	private static final NOWRAP: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, '
		+ '"implementsExtends": {"defaultWrap": "noWrap", "rules": []}}}';

	public function new(): Void {
		super();
	}

	public function testWrappedHeaderGainsABlankAfterIt(): Void {
		final out: String = write('$LONG\nclass Short {}\n', CFG);
		// One assertion spanning the wrap AND the blank, so neither half can
		// pass alone — a typo in `CFG`'s `implementsExtends` block would then
		// be a failure here rather than a silently unexercised knob.
		Assert.isTrue(
			out.indexOf('class LongerName extends LongBaseClass\n\t\timplements ILongFormInterface\n') != -1,
			'precondition: the header must wrap under CFG:\n<$out>'
		);
		Assert.isTrue(
			out.indexOf('implements ILongFormInterface3 {}\n\nclass Short {}') != -1,
			'a wrapped class header is multi-line and its successor needs the blank:\n<$out>'
		);
	}

	public function testWrappedHeaderGainsABlankBeforeIt(): Void {
		final out: String = write('class Short {}\n$LONG\n', CFG);
		Assert.isTrue(
			out.indexOf('class Short {}\n\nclass LongerName extends LongBaseClass\n\t\timplements ILongFormInterface\n') != -1,
			'the blank belongs on the before side too, and only ahead of a header that really wrapped:\n<$out>'
		);
	}

	public function testMetadataOnItsOwnLineIsMultiline(): Void {
		final out: String = write('@:native("x")\ninterface Aa {}\ninterface Bb {}\n', CFG);
		Assert.isTrue(
			out.indexOf('interface Aa {}\n\ninterface Bb {}') != -1,
			'a metadata line above an otherwise single-line type is part of its rendered span:\n<$out>'
		);
	}

	public function testMultilineTypedefIsSeparatedFromItsNeighbour(): Void {
		final out: String = write('typedef Aa = {\n\tvar a: Int;\n};\ntypedef Bb = Int;\n', CFG);
		Assert.isTrue(out.indexOf('};\n\ntypedef Bb = Int;') != -1, 'an anon-body typedef renders multi-line:\n<$out>');
	}

	/**
	 * CONTROL, and the one that separates a MEASURED verdict from a
	 * PREDICTED one. The width term on its own says "too wide to fit, so it
	 * will break"; the renderer refuses when there is nowhere to break, and
	 * the same 164-column header under `NOWRAP` comes back as one over-wide
	 * line that separates nothing. Green at base by construction (the base
	 * writer inserted no blank here either) — what it discriminates against
	 * is the FIRST cut of this slice: drop the `breakableHead` term from
	 * `_measMulti` and this fails while every pin above still passes.
	 */
	public function testUnbreakableOverWideHeaderIsStillOneLine(): Void {
		final out: String = write('$LONG\nclass Short {}\n', NOWRAP);
		Assert.isTrue(
			out.indexOf('implements ILongFormInterface3 {}\nclass Short {}') != -1, 'nowhere to break, so nothing to separate:\n<$out>'
		);
	}

	/**
	 * CONTROL, green at base by construction. Its discriminator is the
	 * MUTATION that forces `_measMulti` to all-true: this test and
	 * `testSourceMultilineThatCollapsesGetsNoBlank` are then the only two
	 * that fail. (It is NOT `betweenSingleLineTypes` — `CFG` declares no
	 * `emptyLines` block, so that knob keeps its default `0` and
	 * `foldBetweenIfNotCascade`'s `opt.betweenSingleLineTypes > 0` gate never
	 * opens; the gap here comes from the source-driven fallback.)
	 */
	public function testTwoSingleLineTypesStayTogether(): Void {
		final out: String = write('interface Aa {}\ninterface Bb {}\n', CFG);
		Assert.isTrue(out.indexOf('interface Aa {}\ninterface Bb {}') != -1, 'single-line neighbours must not gain a blank:\n<$out>');
	}

	/**
	 * CONTROL, green at base by construction. `#if … #end` renders multi-line
	 * and is deliberately outside the ctor set both blank rules gate on;
	 * `blankLinesBeforeCtorIfPrevNot`'s `Conditional` exclusion is what keeps
	 * the metadata-led type below it from claiming a blank. Drop `Conditional`
	 * from that exclusion list and this assertion fails.
	 */
	public function testAConditionalRegionDoesNotHandItsNeighbourABlank(): Void {
		final out: String = write('interface Aa {}\n#if js\ninterface Bb {}\n#end\n@:native("y")\ninterface Dd {}\n', CFG);
		Assert.isTrue(out.indexOf('#end\n@:native("y")\ninterface Dd {}') != -1, 'a conditional region is not a multi-line TYPE:\n<$out>');
	}

	/**
	 * CONTROL, green at base by construction, and the one that separates a
	 * RENDERED answer from a SOURCE-SHAPE one: the heritage clause is written
	 * on its own line and comes back joined, so the declaration is single-line
	 * however the author typed it. A source-span predicate would insert a
	 * blank here.
	 */
	public function testSourceMultilineThatCollapsesGetsNoBlank(): Void {
		final out: String = write('class Aa\n\timplements Bb {}\nclass Cc {}\n', CFG);
		Assert.isTrue(out.indexOf('class Aa implements Bb {}\nclass Cc {}') != -1, 'a collapsed header separates nothing:\n<$out>');
	}

	/** FORWARD GUARD, not a pin: idempotence held at base too, since base added no blank to be lost. */
	public function testWriterIsItsOwnFixedPoint(): Void {
		final once: String = write('$LONG\nclass Short {}\n', CFG);
		Assert.equals(once, write(once, CFG), 'the added blank must survive a second pass unchanged');
	}

	private static inline function write(src: String, config: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(config);
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}

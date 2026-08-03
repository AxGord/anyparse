package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;

/**
 * ω-case-sibling-symmetry — per-SWITCH placement for `FitLine` case bodies.
 *
 * T16 decided each case body on its own width, so one over-wide body
 * dropped below its label while its short siblings stayed inline. The
 * result reads as an accident of measurement rather than a shape the
 * author chose. This slice makes the decision per switch: if ANY sibling
 * takes the width-driven break, every sibling body goes to the next line
 * — the fitting ones and the glued ones alike. If none does, the output
 * is byte-for-byte what T16 produced.
 *
 * MECHANISM, and why it is split across emitter and renderer: the
 * emitter knows every sibling's FLAT width but not the indent; the
 * renderer knows the indent but never sees the sibling set. The cases
 * Star's `@:fmt(caseSiblingSymmetry(...))` pre-pass writes each element
 * once, takes `max(WrapList.flatLength)`, and hands that ONE number to
 * every sibling body; `BodyFit` turns it into an `IfIndentWidthExceeds`
 * probe. Since all siblings render at the same indent and receive the
 * same width, they cannot disagree.
 *
 * WHAT COUNTS AS A TRIGGER — only a width-driven break. An element whose
 * Doc commits to a hardline measures `-1` and contributes nothing:
 *  - a GLUED body (block / lambda / `{`-opening value) — it could not
 *    have shared the label line under any budget, so it is not evidence
 *    the switch is too wide (an all-glued comparator table stays glued);
 *  - a MULTI-STATEMENT body — its spread is AUTHORED, not produced by
 *    the formatter. Decided against triggering on real code: TM's
 *    `FileListSelect.getSaveItemPath` is a lookup switch of three
 *    compact arms plus one twelve-line `case LIST:`, and pulling the
 *    three arms apart to match the long one reads worse than the mix;
 *  - a REFUSED body (`refuseFlatOnComplexExpr`, or a case label carrying
 *    its own trailing comment). Spec T17 rule 4 asked for these to
 *    count; measured on TM first: ZERO case bodies in the tree have the
 *    `A && B` shape, and the label-comment cases are `case X: // no op`
 *    with an EMPTY body, which spreads nothing. The rule would have been
 *    a no-op with a real cost (the refusal is invisible to a flat-width
 *    measure, so it needs a second channel), so it is deliberately not
 *    implemented — see the report for the site list.
 *
 * Per `feedback_unit_test_trivia_writer.md`: the knobs are visible only
 * through `HaxeModuleTriviaParser` / `HaxeModuleTriviaWriter`.
 */
@:nullSafety(Strict)
final class HxCaseBodySymmetrySliceTest extends Test {

	/**
	 * Three one-line bodies at 3 tabs. `case 2:` is the widest; the other
	 * two fit comfortably, so the widest alone decides for all three.
	 */
	private static final MIXED_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n\t\t\tcase 1: aa(bb);\n'
		+ '\t\t\tcase 2: cc(ddddddddddddddd);\n\t\t\tcase _: ee(ff);\n\t\t};\n\t}\n}\n';

	public function new(): Void {
		super();
	}

	public function testAllFitStaysFullyInline(): Void {
		final out: String = write(MIXED_SRC, json(80));
		Assert.isTrue(out.indexOf('case 1: aa(bb);') != -1, 'a switch where nothing breaks keeps every body inline: <$out>');
		Assert.isTrue(out.indexOf('case 2: cc(ddddddddddddddd);') != -1, '<$out>');
		Assert.isTrue(out.indexOf('case _: ee(ff);') != -1, '<$out>');
	}

	public function testOneBreakSpreadsEverySibling(): Void {
		// `case 2: cc(ddddddddddddddd);` is 12 + 28 = 40 columns wide; at 39
		// it breaks, and the two siblings that would fit follow it down —
		// including `case _`.
		final out: String = write(MIXED_SRC, json(39));
		Assert.isTrue(out.indexOf('case 1:\n\t\t\t\taa(bb);') != -1, 'a fitting sibling must follow the switch down: <$out>');
		Assert.isTrue(out.indexOf('case 2:\n\t\t\t\tcc(ddddddddddddddd);') != -1, '<$out>');
		Assert.isTrue(out.indexOf('case _:\n\t\t\t\tee(ff);') != -1, 'the wildcard case is a sibling like any other: <$out>');
	}

	public function testTriggerFlipsAtTheWidestSiblingsBoundary(): Void {
		// Both halves in one test: the break half alone does not
		// discriminate (a narrower budget breaks under T16 too).
		final fits: String = write(MIXED_SRC, json(40));
		Assert.isTrue(
			fits.indexOf('case 2: cc(ddddddddddddddd);') != -1, 'exactly maxLineLength on the WIDEST sibling stays inline: <$fits>'
		);
		Assert.isTrue(fits.indexOf('case 1: aa(bb);') != -1, 'and so do the narrower siblings: <$fits>');
		final over: String = write(MIXED_SRC, json(39));
		Assert.isTrue(over.indexOf('case 2:\n') != -1, 'one column more on the widest sibling spreads the switch: <$over>');
		Assert.isTrue(over.indexOf('case 1: aa(bb);') == -1, 'the narrower siblings spread with it: <$over>');
	}

	public function testGlueAloneIsNotATrigger(): Void {
		// A body that cannot render flat (an arrow lambda opening a block)
		// glues to its label; that is not the formatter spreading anything,
		// so its inline sibling stays inline.
		final src: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n'
			+ '\t\t\tcase 1: (a, b) -> {\n\t\t\t\tfinal t:Int = k(a, b);\n\t\t\t\tt;\n\t\t\t}\n\t\t\tcase _: gg(hh);\n\t\t};\n\t}\n}\n';
		final out: String = write(src, json(140));
		Assert.isTrue(out.indexOf('case 1: (a, b) -> {') != -1, 'the glued body stays glued: <$out>');
		Assert.isTrue(out.indexOf('case _: gg(hh);') != -1, 'and its fitting sibling stays inline: <$out>');
	}

	public function testAGluedSiblingFollowsAWidthTrigger(): Void {
		// The symmetry is "does the body start on the label line", so once
		// something spreads, a glued body moves down too.
		final src: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n'
			+ '\t\t\tcase 1: (a, b) -> {\n\t\t\t\tfinal t:Int = k(a, b);\n\t\t\t\tt;\n\t\t\t}\n\t\t\tcase 2: cc(ddddddddddddddd);\n'
			+ '\t\t};\n\t}\n}\n';
		final out: String = write(src, json(39));
		Assert.isTrue(out.indexOf('case 1:\n\t\t\t\t(a, b) -> {') != -1, 'a glued body must follow a width trigger down: <$out>');
	}

	public function testMultiStatementBodyIsNotATrigger(): Void {
		// Decided from real code (see the class doc): an authored
		// multi-statement body does not pull its compact siblings apart.
		final src: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n\t\t\tcase 1: aa(bb);\n'
			+ '\t\t\tcase _:\n\t\t\t\tfinal t:Int = k();\n\t\t\t\tt;\n\t\t};\n\t}\n}\n';
		final out: String = write(src, json(140));
		Assert.isTrue(out.indexOf('case 1: aa(bb);') != -1, 'a multi-statement sibling must not spread the one-liners: <$out>');
	}

	public function testStatementPositionCaseBodyGetsTheSameSymmetry(): Void {
		final src: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n\t\t\tcase 1: aa(bb);\n'
			+ '\t\t\tcase 2: cc(ddddddddddddddd);\n\t\t}\n\t}\n}\n';
		final out: String = write(src, '{"wrapping": {"maxLineLength": 39}, "sameLine": {"caseBody": "fitLine"}}');
		Assert.isTrue(out.indexOf('case 1:\n\t\t\t\taa(bb);') != -1, 'the statement-position knob coordinates the same way: <$out>');
	}

	public function testNestedSwitchCoordinatesIndependently(): Void {
		// The inner switch's own widest sibling decides for the inner
		// cases; the outer verdict must not leak in (the element opt is
		// always written, never inherited).
		final src: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n'
			+ '\t\t\tcase 1: switch (y) {\n\t\t\t\tcase 3: pp(q);\n\t\t\t\tcase _: rr(s);\n\t\t\t}\n\t\t\tcase 2: cc(ddddddddddddddd);\n'
			+ '\t\t};\n\t}\n}\n';
		final out: String = write(src, json(39));
		Assert.isTrue(out.indexOf('case 3: pp(q);') != -1, 'the inner switch fits on its own and stays inline: <$out>');
		Assert.isTrue(out.indexOf('case _: rr(s);') != -1, '<$out>');
		// Discriminator: the OUTER switch really did spread (so coordination
		// is active in this fixture) while the inner one kept its own verdict.
		Assert.isTrue(out.indexOf('case 2:\n\t\t\t\tcc(ddddddddddddddd);') != -1, 'the outer switch must have spread: <$out>');
	}

	public function testIsIdempotentOnAMixedSwitch(): Void {
		final j: String = json(39);
		final pass1: String = write(MIXED_SRC, j);
		final pass2: String = write(pass1, j);
		final pass3: String = write(pass2, j);
		Assert.equals(pass1, pass2, 'the symmetry verdict must reach its fixed point in ONE pass');
		Assert.equals(pass2, pass3);
	}

	public function testOutputIsIndependentOfSourceLineShape(): Void {
		// The pre-pass measures with `WrapList.flatLength`, which descends
		// `BodyGroup` where the renderer's `fitsFlat` defers it — so the
		// same AST written from inline source and from already-broken
		// source must produce identical bytes.
		final broken: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n\t\t\tcase 1:\n\t\t\t\taa(bb);\n'
			+ '\t\t\tcase 2:\n\t\t\t\tcc(ddddddddddddddd);\n\t\t\tcase _:\n\t\t\t\tee(ff);\n\t\t};\n\t}\n}\n';
		Assert.equals(write(MIXED_SRC, json(39)), write(broken, json(39)));
		Assert.equals(write(MIXED_SRC, json(80)), write(broken, json(80)));
	}

	public function testAlignInlineSwitchCaseBodyComposesWithBothOutcomes(): Void {
		final onFit: String = write(MIXED_SRC, json(80, true));
		Assert.equals(write(MIXED_SRC, json(80, false)), onFit);
		Assert.isTrue(onFit.indexOf('case 1: aa(bb);') != -1, 'the compared output must really be the inline outcome: <$onFit>');
		final onBreak: String = write(MIXED_SRC, json(39, true));
		Assert.equals(write(MIXED_SRC, json(39, false)), onBreak);
		Assert.isTrue(onBreak.indexOf('case 1:\n') != -1, 'the compared output must really be the spread outcome: <$onBreak>');
	}

	public function testKnobOffIsInert(): Void {
		final keep: String = write(MIXED_SRC, '{"wrapping": {"maxLineLength": 39}, "sameLine": {"expressionCase": "keep"}}');
		Assert.isTrue(keep.indexOf('case 1: aa(bb);') != -1, 'Keep still preserves the source shape, symmetry or not: <$keep>');
		Assert.isTrue(keep.indexOf('case 2: cc(ddddddddddddddd);') != -1, '<$keep>');
	}

	private inline function json(maxLineLength: Int, alignInline: Bool = false): String {
		return '{"wrapping": {"maxLineLength": $maxLineLength}, "indentation": {"alignInlineSwitchCaseBody": $alignInline'
			+ '}, "sameLine": {"expressionCase": "fitLine"}}';
	}

	private inline function write(src: String, cfg: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson(cfg));
	}

}

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
 *    count; measured on TM first, and the measurement is what decided
 *    it. ZERO case bodies in the tree have the `A && B` shape the
 *    complex-expression refusal targets, so that half is a no-op on real
 *    code. The label-comment half has 15 sites, and they split: 7 have an
 *    EMPTY body (`case X: // no op`) and spread nothing, 7 more are
 *    MULTI-STATEMENT and are already excluded by the rule above — which
 *    leaves exactly ONE site in the whole tree where counting refusals
 *    would change anything (`PitchArea.onStageKeyDown`, whose sibling is
 *    itself a wrapped-pattern case). Buying one site costs a second,
 *    non-flat-width channel through the pre-pass, since a refusal is
 *    invisible to `flatLength`. Deliberately not implemented.
 *
 * A `#if`-GUARDED CASE REGION IS NOT ONE ELEMENT (ω-if-leader-case-symmetry).
 * Measured whole it always answers `-1` — its Doc carries the directive
 * hardlines — so it could FOLLOW a sibling's break and never LEAD one. The
 * Star's generated `caseSiblingUnits_HxSwitchCase` flattener expands the
 * region into the inner case ELEMENTS of every branch (`#if` / `#elseif` /
 * `#else` are alternatives, so the maximum across them is the conservative
 * trigger) and each is measured on the terms above — a glued or
 * multi-statement inner case still contributes nothing. Two shapes stay
 * whole: `CondSpliceCase`, whose labels are byte-verbatim so it has no
 * inner case list, and a pattern-scope conditional (`case #if js "a" #else
 * "b" #end:`), which is a plain `CaseBranch` that already measures flat.
 * `HxCondSpliceSwitchOpen.cases` is opted in for the same reason a switch
 * is; `HxConditionalCase.body` / `elseBody` and `HxElseifCase.body` are
 * deliberately NOT, so the enclosing switch's verdict flows into the region
 * instead of a per-region pre-pass overwriting it.
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

	/**
	 * `MIXED_SRC` with its widest body — the same 12 + 28 = 40 columns —
	 * moved inside a `#if` region. Before ω-if-leader-case-symmetry the
	 * region was ONE element measuring `-1`, so this switch kept the mixed
	 * shape at 39: `case 2` alone below its label, its two siblings inline.
	 */
	private static final CONDITIONAL_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n'
		+ '\t\t\tcase 1: aa(bb);\n#if js\n\t\t\tcase 2: cc(ddddddddddddddd);\n#end\n\t\t\tcase _: ee(ff);\n\t\t};\n\t}\n}\n';

	/** The widest case (still 40 columns) sits in the `#else` branch, behind an `#elseif` that also holds one. */
	private static final BRANCHES_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n\t\t\tcase 1: aa(bb);\n'
		+ '#if js\n\t\t\tcase 2: gg(h);\n#elseif cpp\n\t\t\tcase 3: ii(jj);\n#else\n\t\t\tcase 4: cc(ddddddddddddddd);\n#end\n'
		+ '\t\t\tcase _: ee(ff);\n\t\t};\n\t}\n}\n';

	/** The widest case sits inside a `#if` nested in another `#if`. */
	private static final NESTED_REGION_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n'
		+ '\t\t\tcase 1: aa(bb);\n#if js\n#if debug\n\t\t\tcase 2: cc(ddddddddddddddd);\n#end\n\t\t\tcase 3: gg(h);\n#end\n'
		+ '\t\t\tcase _: ee(ff);\n\t\t};\n\t}\n}\n';

	/** A `#if` region whose only case has a block-lambda body — a unit that could not have shared its label line at any width. */
	private static final GLUED_REGION_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n#if js\n'
		+ '\t\t\tcase 1: (a, b) -> {\n\t\t\t\tfinal t:Int = kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk(a, b);\n\t\t\t\tt;\n\t\t\t}\n'
		+ '#end\n\t\t\tcase _: gg(hh);\n\t\t};\n\t}\n}\n';

	/**
	 * `HxCondSpliceSwitchOpen` — a token-splice region whose every branch
	 * opens a block and a `switch (…) {` header, with the case list shared
	 * after `#end`. Its cases sit at 4 tabs, so the widest is 16 + 28 = 44
	 * columns.
	 */
	private static final SPLICE_SWITCH_OPEN_SRC: String = 'class M {\n\tfunction f():Void {\n#if utf16\n\t\tfor (c in it(tmp)) {\n'
		+ '\t\t\tswitch (c) {\n#else\n\t\tfor (i in 0...tmp.length) {\n\t\t\tswitch (fast(tmp, i)) {\n#end\n'
		+ '\t\t\t\tcase 1: aa(bb);\n\t\t\t\tcase 2: cc(ddddddddddddddd);\n\t\t\t\tcase _: ee(ff);\n\t\t\t}\n\t\t}\n\t}\n}\n';

	/** `HxSwitchCase.CondSpliceCase` — a region that splits a case's LABELS from the body they share after `#end`. */
	private static final SPLICE_CASE_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar w = switch ext(a) {\n#if hxbitmini\n'
		+ '\t\t\tcase ATLAS, BINATLAS:\n#else\n\t\t\tcase ATLAS:\n#end\n\t\t\t\tcc(ddddddddddddddd);\n\t\t\tcase PNG: tiles[a];\n'
		+ '\t\t};\n\t}\n}\n';

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

	public function testDeeplyNestedSwitchesStayLinear(): Void {
		// ω-case-sym-linear regression pin. The coordination pre-pass writes
		// each element twice (measure + emit) and the probe holds the body in
		// BOTH branches, so a switch nested d deep used to cost 2^d — twice
		// over: once in writer invocations (the pre-pass re-entered nested
		// pre-passes) and once in Doc-walk node visits (`CollapsePass` and its
		// two both-branch siblings descended break AND flat). Measured on the
		// shape below: depth 15 took 6.0s and depth 17 took 23.4s before the
		// fix, 0.13s after — flat with the knobs off.
		// utest has no timing assertion, so this pins the OUTPUT only —
		// correct and idempotent at a depth that used to cost seconds. On the
		// pre-fix engine this very fixture still PASSED, just slowly, so the
		// test does not discriminate the fix by itself; what it buys is a
		// canary whose cost doubles per depth if either half of the fix is
		// undone (add two levels and the suite visibly stalls). The
		// discriminating evidence is the CLI timing in the slice report.
		final src: String = deepSwitch(15);
		final j: String = '{"wrapping": {"maxLineLength": 140}, "sameLine": {"caseBody": "fitLine", "expressionCase": "fitLine"}}';
		final pass1: String = write(src, j);
		Assert.equals(pass1, write(pass1, j), 'a deeply nested switch must still reach its fixed point in one pass');
		Assert.isTrue(pass1.indexOf('case 3: aa(bb);') != -1, 'the innermost body still fits and stays inline: <$pass1>');
	}

	/**
	 * Probe1 shape: the only over-wide body sits inside a `#if` region.
	 * Measured whole, the region's Doc carries directive hardlines and
	 * answers `-1`, so before this slice it could only FOLLOW a sibling's
	 * break — the switch kept the mixed shape. The flattener measures the
	 * region's inner case ELEMENT instead, so it now LEADS: all three
	 * bodies drop below their labels.
	 */
	public function testAConditionalRegionLeadsTheSpread(): Void {
		final out: String = write(CONDITIONAL_SRC, json(39));
		Assert.isTrue(out.indexOf('case 1:\n\t\t\t\taa(bb);') != -1, 'a plain sibling must follow a `#if`-guarded trigger: <$out>');
		Assert.isTrue(out.indexOf('case 2:\n\t\t\t\tcc(ddddddddddddddd);') != -1, 'the guarded body itself breaks: <$out>');
		Assert.isTrue(out.indexOf('case _:\n\t\t\t\tee(ff);') != -1, 'and so does the wildcard: <$out>');
	}

	/**
	 * One column wider than the region's own case and the switch stays
	 * fully inline — the trigger is the widest UNIT's width, never the
	 * mere presence of a directive region.
	 *
	 * A guard, NOT a discriminator: the pre-slice engine never triggered
	 * on a region either, so this shape is byte-identical there. What it
	 * pins is over-triggering, and it is the companion half of
	 * `testAConditionalRegionLeadsTheSpread` (which does discriminate).
	 */
	public function testARegionIsNotATriggerByItself(): Void {
		final out: String = write(CONDITIONAL_SRC, json(40));
		Assert.isTrue(out.indexOf('case 1: aa(bb);') != -1, 'exactly maxLineLength on the widest unit stays inline: <$out>');
		Assert.isTrue(out.indexOf('case 2: cc(ddddddddddddddd);') != -1, 'including the guarded one: <$out>');
		Assert.isTrue(out.indexOf('case _: ee(ff);') != -1, '<$out>');
	}

	/**
	 * The widest case sits in the `#else` branch, behind an `#elseif` that
	 * holds one too. Branches are ALTERNATIVES — only one is ever compiled
	 * — so the pre-pass takes the maximum ACROSS all of them and the one
	 * emitted file serves every compilation variant.
	 */
	public function testTheWidestUnitMayLiveInAnyBranch(): Void {
		final out: String = write(BRANCHES_SRC, json(39));
		Assert.isTrue(out.indexOf('case 1:\n\t\t\t\taa(bb);') != -1, 'an `#else`-branch case must lead the spread: <$out>');
		Assert.isTrue(out.indexOf('case 2:\n\t\t\t\tgg(h);') != -1, 'the `#if` branch spreads with it: <$out>');
		Assert.isTrue(out.indexOf('case 3:\n\t\t\t\tii(jj);') != -1, 'and so does the `#elseif` branch: <$out>');
		Assert.isTrue(out.indexOf('case 4:\n\t\t\t\tcc(ddddddddddddddd);') != -1, '<$out>');
		Assert.isTrue(out.indexOf('case _:\n\t\t\t\tee(ff);') != -1, '<$out>');
	}

	/**
	 * `#if` inside `#if`. The flattener recurses because case-scope
	 * conditionals do NOT lift indent (`HxConditionalCase.body` carries
	 * `padLeading, padTrailing, conditionalBodyIndent`, never
	 * `alignedNestedIncrease`), so a doubly-nested case renders at the
	 * SAME indent as the switch's own and its width is comparable.
	 */
	public function testANestedRegionStillLeads(): Void {
		final out: String = write(NESTED_REGION_SRC, json(39));
		Assert.isTrue(out.indexOf('case 1:\n\t\t\t\taa(bb);') != -1, 'a doubly-nested `#if` case must lead the spread: <$out>');
		Assert.isTrue(out.indexOf('case 2:\n\t\t\t\tcc(ddddddddddddddd);') != -1, '<$out>');
		Assert.isTrue(out.indexOf('case 3:\n\t\t\t\tgg(h);') != -1, 'the outer region spreads with it: <$out>');
		Assert.isTrue(out.indexOf('case _:\n\t\t\t\tee(ff);') != -1, '<$out>');
	}

	/**
	 * A `#if` region whose only case has a block-lambda body. The unit
	 * measures `-1` on exactly the terms a top-level glued sibling does,
	 * so it is no evidence the switch is too wide and the plain sibling
	 * stays inline. This is the guard against measuring a region's Doc
	 * SEGMENTS rather than its units: that lambda's interior statement
	 * line is 60+ columns and would read as an enormous width.
	 *
	 * A guard, NOT a discriminator — byte-identical on the pre-slice
	 * engine, which measured the whole region as `-1` anyway.
	 */
	public function testGlueInsideARegionIsNotATrigger(): Void {
		final out: String = write(GLUED_REGION_SRC, json(140));
		Assert.isTrue(out.indexOf('case 1: (a, b) -> {') != -1, 'the glued body inside the region stays glued: <$out>');
		Assert.isTrue(out.indexOf('case _: gg(hh);') != -1, 'and its plain sibling stays inline: <$out>');
	}

	/**
	 * `#if <open> switch (…) { #else … #end <cases> } }` — the shared case
	 * list of a token-splice switch header. It is a ROOT case list with no
	 * enclosing coordinated Star, so before the opt-in it got no
	 * coordination at all and its one over-wide body broke alone.
	 */
	public function testCondSpliceSwitchOpenCoordinatesItsSharedCaseList(): Void {
		final out: String = write(SPLICE_SWITCH_OPEN_SRC, jsonCaseBody(43));
		Assert.isTrue(out.indexOf('case 1:\n\t\t\t\t\taa(bb);') != -1, 'a shared case list coordinates as one switch: <$out>');
		Assert.isTrue(out.indexOf('case 2:\n\t\t\t\t\tcc(ddddddddddddddd);') != -1, '<$out>');
		Assert.isTrue(out.indexOf('case _:\n\t\t\t\t\tee(ff);') != -1, '<$out>');
	}

	/** One column wider than its widest case and the same shared list stays fully inline (the fits half of the pair above). */
	public function testCondSpliceSwitchOpenStaysInlineWhenEverythingFits(): Void {
		final out: String = write(SPLICE_SWITCH_OPEN_SRC, jsonCaseBody(44));
		Assert.isTrue(out.indexOf('case 1: aa(bb);') != -1, 'nothing spreads while the widest case fits: <$out>');
		Assert.isTrue(out.indexOf('case 2: cc(ddddddddddddddd);') != -1, '<$out>');
		Assert.isTrue(out.indexOf('case _: ee(ff);') != -1, '<$out>');
	}

	/**
	 * `HxSwitchCase.CondSpliceCase` — a region that splits a case's LABELS
	 * from the body they share after `#end`. Those labels are captured
	 * byte-verbatim in an `HxCondSpliceRaw`, so there is no inner
	 * case-element list to measure and the element stays ONE
	 * non-contributing unit: the plain sibling keeps its own verdict.
	 *
	 * A guard, NOT a discriminator — the pre-slice engine also measured
	 * this element as `-1`.
	 */
	public function testCondSpliceCaseContributesNothing(): Void {
		final out: String = write(SPLICE_CASE_SRC, json(39));
		Assert.isTrue(out.indexOf('case PNG: tiles[a];') != -1, 'a label-splice region must not spread its siblings: <$out>');
	}

	public function testIsIdempotentOnAConditionalSwitch(): Void {
		final j: String = json(39);
		final pass1: String = write(CONDITIONAL_SRC, j);
		final pass2: String = write(pass1, j);
		final pass3: String = write(pass2, j);
		Assert.equals(pass1, pass2, 'the region-aware verdict must reach its fixed point in ONE pass');
		Assert.equals(pass2, pass3);
	}

	public function testKnobOffIsInertOnAConditionalSwitch(): Void {
		final keep: String = write(CONDITIONAL_SRC, '{"wrapping": {"maxLineLength": 39}, "sameLine": {"expressionCase": "keep"}}');
		Assert.isTrue(keep.indexOf('case 1: aa(bb);') != -1, 'Keep preserves the source shape, region or not: <$keep>');
		Assert.isTrue(keep.indexOf('case 2: cc(ddddddddddddddd);') != -1, '<$keep>');
		Assert.isTrue(keep.indexOf('case _: ee(ff);') != -1, '<$keep>');
	}

	private inline function jsonCaseBody(maxLineLength: Int): String {
		return '{"wrapping": {"maxLineLength": $maxLineLength}, "sameLine": {"caseBody": "fitLine"}}';
	}

	private inline function json(maxLineLength: Int, alignInline: Bool = false): String {
		return '{"wrapping": {"maxLineLength": $maxLineLength}, "indentation": {"alignInlineSwitchCaseBody": $alignInline'
			+ '}, "sameLine": {"expressionCase": "fitLine"}}';
	}

	private inline function write(src: String, cfg: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson(cfg));
	}

	/** `d` switch statements nested through each other's first case body. */
	private static function deepSwitch(d: Int): String {
		var body: String = 'aa(bb);';
		for (i in 0...d) body = 'switch (y$i) {\n\t\t\tcase 3: $body\n\t\t\tcase _: cc(dd);\n\t\t}';
		return 'class D {\n\tfunction f():Void {\n\t\t$body\n\t}\n}\n';
	}

}

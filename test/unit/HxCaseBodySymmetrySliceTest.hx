package unit;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

/**
 * ω-case-sibling-symmetry — per-SWITCH placement for `FitLine` case bodies.
 *
 * T16 decided each case body on its own, so one body that landed below its
 * label left its short siblings inline. The result reads as an accident of
 * measurement rather than a shape the author chose. This slice makes the
 * decision per switch: if ANY case body renders on the line(s) BELOW its
 * label, every sibling body goes below its label too. If none does, the
 * output is byte-for-byte what T16 produced.
 *
 * MECHANISM, and why it is split across emitter and renderer: the emitter
 * knows every sibling's shape and FLAT width but not the indent; the
 * renderer knows the indent but never sees the sibling set. The cases
 * Star's `@:fmt(caseSiblingSymmetry(...))` pre-pass hands ONE number to
 * every sibling body and `BodyFit` turns it into an `IfIndentWidthExceeds`
 * probe. Since all siblings render at the same indent and receive the same
 * number, they cannot disagree.
 *
 * WHAT COUNTS AS A TRIGGER — any unit that is below its label, by either of
 * two channels.
 *
 * STRUCTURAL, decided without measuring anything
 * (`caseUnitStructuralBreak_HxSwitchCase`):
 *  - a MULTI-STATEMENT body — two or more statements cannot share the label
 *    line at any budget;
 *  - a REFUSED body — one statement whose outermost expression is `&&` or
 *    `||`, which `refuseFlatOnComplexExpr` refuses inline;
 *  - a `CondSpliceCase` region — the body it shares after `#end` is
 *    mandatory and renders below the labels it was split from at every
 *    budget.
 * The pre-pass substitutes `BodyFit.SIBLING_FORCE_BREAK` on the first such
 * unit and skips the width measurement entirely.
 *
 * WIDTH, the original channel and now the fallback: the widest unit's flat
 * width does not fit at the switch's indent — or some unit measures `-1`
 * AND holds a single keyword-led control-flow statement, which
 * `BodyFit.fitLineLayout` refuses the glue, so it renders below its own
 * label (`HxCaseBodyControlFlowGlueTest`).
 *
 * NOT triggers, and each for its own reason:
 *  - an EMPTY body (`case X:` with no statements) — there is no body to
 *    place below the label, and a forced break would have nothing to move;
 *  - a GLUED body (a block / lambda / `{`-opening value) — its FIRST line
 *    SHARES the label line, so it is not a below-label placement. It still
 *    MOVES under someone else's trigger; it just never leads. An all-glued
 *    comparator table therefore stays glued;
 *  - a glue that the width gate turns into a break. That verdict is reached
 *    at the LIVE PEN COLUMN, which no emitter-side walk can see, so the
 *    pre-pass never learns of it. The known residual, pinned by
 *    `HxGlueWidthSliceTest.testGlueTurnedBreakIsNotASiblingSymmetryTrigger`;
 *  - a body refused by a COMMENT (a leading comment on the body's
 *    first statement, or a trailing comment captured on the label — an
 *    ORPHAN trailing comment in the body stopped refusing at
 *    omega-case-trail-comment-inline, see
 *    `HxCaseBodyTrailCommentInlineTest`). Those live in trivia slots the structural
 *    predicate cannot read without answering differently per AST family —
 *    see `HxCasePredLowering.caseUnitStructuralBreakField`.
 *
 * A `#if`-GUARDED CASE REGION IS NOT ONE ELEMENT (ω-if-leader-case-symmetry).
 * Measured whole it always answers `-1` — its Doc carries the directive
 * hardlines — so it could FOLLOW a sibling's break and never LEAD one. The
 * Star's generated `caseSiblingUnits_HxSwitchCase` flattener expands the
 * region into the inner case ELEMENTS of every branch (`#if` / `#elseif` /
 * `#else` are alternatives, so the maximum across them is the conservative
 * trigger) and each is judged on the terms above — by width AND by shape, so
 * a multi-statement case inside a region leads too. Two shapes stay whole:
 * `CondSpliceCase`, whose labels are byte-verbatim so it has no inner case
 * list (it still LEADS, as ONE unit and structurally — the body it shares
 * after `#end` is always below those labels), and a pattern-scope
 * conditional (`case #if js "a" #else "b" #end:`), which is a plain
 * `CaseBranch` that already measures flat.
 * `HxCondSpliceSwitchOpen.cases` is opted in for the same reason a switch is;
 * `HxConditionalCase.body` / `elseBody` and `HxElseifCase.body` are
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

	/** A switch whose ONLY element is a `#if` region — the whole case list lives inside one directive block. */
	private static final LONE_REGION_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n#if js\n'
		+ '\t\t\tcase 1: aa(bb);\n\t\t\tcase 2: cc(ddddddddddddddd);\n#end\n\t\t};\n\t}\n}\n';

	/** A PATTERN-scope conditional — the region sits inside the pattern list and the `:` is outside it. */
	private static final PATTERN_REGION_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n'
		+ '\t\t\tcase #if js "a" #else "b" #end: cc(dd);\n\t\t\tcase _: ee(ff);\n\t\t};\n\t}\n}\n';

	/** `HxSwitchCase.CondSpliceCase` — a region that splits a case's LABELS from the body they share after `#end`. */
	private static final SPLICE_CASE_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar w = switch ext(a) {\n#if hxbitmini\n'
		+ '\t\t\tcase ATLAS, BINATLAS:\n#else\n\t\t\tcase ATLAS:\n#end\n\t\t\t\tcc(ddddddddddddddd);\n\t\t\tcase PNG: tiles[a];\n'
		+ '\t\t};\n\t}\n}\n';

	/**
	 * A one-line body beside a two-statement one. Nothing here is over-wide
	 * — the trigger is the SHAPE of `case 2`'s body, not any width.
	 */
	private static final MULTI_STMT_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n'
		+ '\t\t\tcase 1: aa(bb);\n\t\t\tcase 2:\n\t\t\t\tfinal t:Int = k();\n\t\t\t\tt;\n\t\t};\n\t}\n}\n';

	/** A single-statement body the flat-refusal gate rejects (outermost `&&`) beside a body that would have fit. */
	private static final REFUSED_FLAT_SRC: String =
		'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n\t\t\tcase 1: a && b;\n\t\t\tcase 2: cc(d);\n\t\t};\n\t}\n}\n';

	/** `MULTI_STMT_SRC` with the multi-statement branch as `default:` — the other body-carrying ctor and field. */
	private static final DEFAULT_MULTI_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n'
		+ '\t\t\tcase 1: aa(bb);\n\t\t\tdefault:\n\t\t\t\tfinal t:Int = k();\n\t\t\t\tt;\n\t\t};\n\t}\n}\n';

	/** A block-lambda (GLUED) body beside a two-statement one: the glue cannot lead, but it must follow. */
	private static final GLUED_UNDER_TRIGGER_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n'
		+ '\t\t\tcase 1: (a, b) -> {\n\t\t\t\tfinal t:Int = k(a, b);\n\t\t\t\tt;\n\t\t\t}\n\t\t\tcase 2:\n'
		+ '\t\t\t\tfinal u:Int = m();\n\t\t\t\tu;\n\t\t};\n\t}\n}\n';

	/** The two-statement body sits inside a `#if` region; its plain sibling is outside it. */
	private static final COND_MULTI_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n'
		+ '\t\t\tcase 1: aa(bb);\n#if js\n\t\t\tcase 2:\n\t\t\t\tfinal t:Int = k();\n\t\t\t\tt;\n#end\n\t\t};\n\t}\n}\n';

	/** An EMPTY case body beside a one-line one — no body to place, so nothing to spread. */
	private static final EMPTY_BODY_SRC: String =
		'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n\t\t\tcase 1:\n\t\t\tcase _: ee(ff);\n\t\t};\n\t}\n}\n';

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
		final src: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n\t\t\tcase 1: (a, b) -> {\n'
			+ '\t\t\t\tfinal t:Int = k(a, b);\n\t\t\t\tt;\n\t\t\t}\n\t\t\tcase 2: cc(ddddddddddddddd);\n\t\t};\n\t}\n}\n';
		final out: String = write(src, json(39));
		Assert.isTrue(out.indexOf('case 1:\n\t\t\t\t(a, b) -> {') != -1, 'a glued body must follow a width trigger down: <$out>');
	}

	/**
	 * A multi-statement body is a STRUCTURAL trigger: its statements already
	 * sit below the label at every budget, so the per-switch rule "if one
	 * body is below its label, all are" fires with no width involved. The
	 * budget here is 140 and the widest line is a fraction of it.
	 */
	public function testMultiStatementSiblingSpreadsBreak(): Void {
		final out: String = write(MULTI_STMT_SRC, json(140));
		Assert.isTrue(out.indexOf('case 1:\n\t\t\t\taa(bb);') != -1, 'a one-liner must follow a multi-statement sibling down: <$out>');
		Assert.isTrue(out.indexOf('case 2:\n\t\t\t\tfinal t:Int = k();') != -1, 'the multi-statement body stays below its label: <$out>');
	}

	/**
	 * The other structural shape: a single-statement body whose outermost
	 * expression is `&&` / `||`. `refuseFlatOnComplexExpr` refuses it inline,
	 * so it renders below its label and its fitting sibling follows it there.
	 */
	public function testRefusedFlatSiblingSpreadsBreak(): Void {
		final out: String = write(REFUSED_FLAT_SRC, json(140));
		Assert.isTrue(out.indexOf('case 2:\n\t\t\t\tcc(d);') != -1, 'a fitting sibling must follow a refused body down: <$out>');
		Assert.isTrue(out.indexOf('case 1:\n\t\t\t\ta && b;') != -1, 'the refused body itself sits below its label: <$out>');
	}

	/** `default:` carries its statements in a different ctor and field (`HxDefaultBranch.stmts`) and triggers the same way. */
	public function testDefaultBranchMultiStatementSpreads(): Void {
		final out: String = write(DEFAULT_MULTI_SRC, json(140));
		Assert.isTrue(out.indexOf('case 1:\n\t\t\t\taa(bb);') != -1, 'a `default:` body spreads its case siblings: <$out>');
		Assert.isTrue(out.indexOf('default:\n\t\t\t\tfinal t:Int = k();') != -1, '<$out>');
	}

	/**
	 * A glued body never LEADS — its first line SHARES the label line, which
	 * is not a below-label placement — but it must FOLLOW: under a structural
	 * trigger it moves below its label with everyone else.
	 */
	public function testGluedBodyMovesUnderStructuralTrigger(): Void {
		final out: String = write(GLUED_UNDER_TRIGGER_SRC, json(140));
		Assert.isTrue(out.indexOf('case 1:\n\t\t\t\t(a, b) -> {') != -1, 'a glued body must follow a structural trigger down: <$out>');
	}

	/**
	 * The structural verdict is taken per expanded UNIT, so a multi-statement
	 * case inside a `#if` region leads the spread exactly as an over-wide one
	 * does.
	 */
	public function testConditionalRegionInnerMultiStatementSpreads(): Void {
		final out: String = write(COND_MULTI_SRC, json(140));
		Assert.isTrue(out.indexOf('case 1:\n\t\t\t\taa(bb);') != -1, 'a plain sibling must follow a guarded multi-statement body: <$out>');
		Assert.isTrue(out.indexOf('case 2:\n\t\t\t\tfinal t:Int = k();') != -1, '<$out>');
	}

	/**
	 * An EMPTY body is not a trigger: there is no body to place below the
	 * label, and a forced break would have nothing to move. A guard against
	 * over-triggering, NOT a discriminator — byte-identical before this
	 * widening.
	 */
	public function testEmptyBodyDoesNotTrigger(): Void {
		final out: String = write(EMPTY_BODY_SRC, json(140));
		Assert.isTrue(out.indexOf('case _: ee(ff);') != -1, 'an empty-body case must not spread its sibling: <$out>');
	}

	/**
	 * The structural verdict must reach its fixed point in ONE pass, like the
	 * width one. The first assertion of each round pins that the fixture
	 * really did spread, so what is being checked is the idempotence of the
	 * NEW shape and not of the pre-widening one.
	 */
	public function testIsIdempotentOnAStructurallySpreadSwitch(): Void {
		final j: String = json(140);
		final fixtures: Array<{ name: String, src: String }> = [
			{ name: 'MULTI_STMT_SRC', src: MULTI_STMT_SRC },
			{ name: 'REFUSED_FLAT_SRC', src: REFUSED_FLAT_SRC },
			{ name: 'GLUED_UNDER_TRIGGER_SRC', src: GLUED_UNDER_TRIGGER_SRC },
			{ name: 'COND_MULTI_SRC', src: COND_MULTI_SRC }
		];
		for (f in fixtures) {
			final pass1: String = write(f.src, j);
			Assert.isTrue(pass1.indexOf('case 1:\n') != -1, '${f.name} must really have spread: <$pass1>');
			final pass2: String = write(pass1, j);
			Assert.equals(pass1, pass2, '${f.name}: a structural spread must reach its fixed point in one pass');
			Assert.equals(pass2, write(pass2, j), '${f.name}: the fixed point must hold on a third pass');
		}
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
		final src: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n\t\t\tcase 1: switch (y) {\n'
			+ '\t\t\t\tcase 3: pp(q);\n\t\t\t\tcase _: rr(s);\n\t\t\t}\n\t\t\tcase 2: cc(ddddddddddddddd);\n\t\t};\n\t}\n}\n';
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
	 * `#if` inside `#if`. The flattener recurses, and under the DEFAULT
	 * `indentation.conditionalPolicy: aligned` a doubly-nested case renders at
	 * the SAME indent as the switch's own, so its width is comparable. (The
	 * `Increase` / `Decrease` policies lift a region body one level per depth
	 * and a switch with a region can still come out asymmetric there — a
	 * limitation carried over from before this slice, unpinned by any fixture.)
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
	 * case-element list and the region stays ONE unit — but that unit IS a
	 * structural trigger: `HxCondSpliceCase.tail` is mandatory, so the shared
	 * body always renders on the line(s) below the labels, and the
	 * per-switch rule takes the plain sibling down with it.
	 *
	 * The budget plays no part: `case PNG: tiles[a];` is 31 columns against
	 * 39 and still goes below its label.
	 */
	public function testCondSpliceCaseTriggersSpread(): Void {
		final out: String = write(SPLICE_CASE_SRC, json(39));
		Assert.isTrue(out.indexOf('case PNG:\n\t\t\t\ttiles[a];') != -1, 'a label-splice region must spread its siblings: <$out>');
	}

	/**
	 * A switch whose ONLY element is a `#if` region holding several cases.
	 * The pre-slice one-element short-circuit read `_arr.length > 1` and
	 * skipped the pre-pass here, so the region's two cases decided
	 * separately and kept the mixed shape; the count is now over EXPANDED
	 * units, so the two coordinate like any pair of siblings.
	 */
	public function testALoneRegionsCasesCoordinateWithEachOther(): Void {
		final out: String = write(LONE_REGION_SRC, json(39));
		Assert.isTrue(out.indexOf('case 1:\n\t\t\t\taa(bb);') != -1, 'the region\'s narrower case must follow its widest: <$out>');
		Assert.isTrue(out.indexOf('case 2:\n\t\t\t\tcc(ddddddddddddddd);') != -1, '<$out>');
	}

	/**
	 * A PATTERN-scope conditional (`case #if js "a" #else "b" #end:`) is a
	 * plain `CaseBranch`, not a `Conditional`, so the flattener never sees
	 * it — and it needs no flattening: the directives render inline in the
	 * flat walk, so the element already measures a real width and already
	 * leads. Pins that the region expansion did not capture the shape (it
	 * would then answer an empty unit list and the element would stop
	 * contributing). A guard, NOT a discriminator — byte-identical on the
	 * pre-slice engine.
	 */
	public function testAPatternScopeConditionalStillMeasuresFlat(): Void {
		final wide: String = write(PATTERN_REGION_SRC, json(51));
		Assert.isTrue(wide.indexOf('#end: cc(dd);') != -1, 'the widest unit fits, so nothing spreads: <$wide>');
		Assert.isTrue(wide.indexOf('case _: ee(ff);') != -1, '<$wide>');
		final over: String = write(PATTERN_REGION_SRC, json(50));
		Assert.isTrue(over.indexOf('#end:\n\t\t\t\tcc(dd);') != -1, 'one column less and the pattern-region case leads: <$over>');
		Assert.isTrue(over.indexOf('case _:\n\t\t\t\tee(ff);') != -1, 'its plain sibling follows it down: <$over>');
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

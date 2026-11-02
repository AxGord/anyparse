package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `sameLine.caseSiblings: anyBreak`: one placement decision per SWITCH for `FitLine` case bodies. If ANY case body
 * renders below its label, every sibling does; if none does, the output is what per-body placement produced.
 *
 * A body emits a slot with both of its forms and a vote; the case list decides over its finished Doc
 * (`anyparse.format.SiblingShare`). A multi-statement, refused (`&&` / `||` outermost) or `CondSpliceCase` body leads
 * by shape, with no width read; otherwise the widest unit's flat width decides. An empty body, a glued body and a body
 * refused by a comment never lead, though a glued body still moves under someone else's trigger.
 *
 * A `#if` region is found in the list's Doc, so its cases vote like any other. `HxCondSpliceSwitchOpen.cases` is a
 * whole switch and shares by itself; `HxConditionalCase.body` and `HxElseifCase.body` do not, so the enclosing
 * switch's verdict flows into the region.
 */
@:nullSafety(Strict)
final class HxCaseBodySymmetrySliceTest extends Test {

	/**
	 * Three one-line bodies at 3 tabs. `case 2:` is the widest; the other
	 * two fit comfortably, so the widest alone decides for all three.
	 */
	private static final MIXED_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n\t\t\tcase 1: aa(bb);\n'
		+ '\t\t\tcase 2: cc(ddddddddddddddd);\n\t\t\tcase _: ee(ff);\n\t\t};\n\t}\n}\n';

	/** `MIXED_SRC` with its widest body moved inside a `#if` region. */
	private static final CONDITIONAL_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n'
		+ '\t\t\tcase 1: aa(bb);\n#if js\n\t\t\tcase 2: cc(ddddddddddddddd);\n#end\n\t\t\tcase _: ee(ff);\n\t\t};\n\t}\n}\n';

	/** The widest case sits in the `#else` branch, behind an `#elseif` that also holds one. */
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

	/** A list of cases written twice over the same labels' splice, so two slots lead under a policy that is not `fitLine`. */
	private static final TWO_SPLICE_CASES_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar w = switch ext(a) {\n#if hxbitmini\n'
		+ '\t\t\tcase ATLAS, BINATLAS:\n#else\n\t\t\tcase ATLAS:\n#end\n\t\t\t\tcc(ddddddddddddddd);\n#if js\n\t\t\tcase RAW, TGA:\n#else\n'
		+ '\t\t\tcase RAW:\n#end\n\t\t\t\tgg(h);\n\t\t\tcase PNG: tiles[a];\n\t\t};\n\t}\n}\n';

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

	/** The object-literal rule that makes a pivot literal of the offer's fixture, with the key on. */
	private static final PIVOT_CONFIG: String = '{"indentation": {"character": "tab", "tabWidth": 4, "alignInlineSwitchCaseBody": true}, '
		+ '"sameLine": {"caseSiblings": "anyBreak", "caseBody": "fitLine", "expressionCase": '
		+ '"fitLine"}, "wrapping": {"maxLineLength": 140, "objectLiteral": {'
		+ '"defaultWrap": "onePerLine", "rules": ['
		+ '{"conditions": [{"cond": "totalItemLength <= n", "value": 140}], "type": "noWrap"}]}}}';

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
		// discriminate (a narrower budget breaks under per-body placement too).
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
	 * label, and a forced break would have nothing to move.
	 */
	public function testEmptyBodyDoesNotTrigger(): Void {
		final out: String = write(EMPTY_BODY_SRC, json(140));
		Assert.isTrue(out.indexOf('case _: ee(ff);') != -1, 'an empty-body case must not spread its sibling: <$out>');
	}

	/**
	 * The structural verdict must reach its fixed point in ONE pass, like the
	 * width one. The first assertion of each round pins that the fixture
	 * really did spread.
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
		final out: String = write(
			src, '{"wrapping": {"maxLineLength": 39}, "sameLine": {"caseSiblings": "anyBreak", "caseBody": "fitLine"}}'
		);
		Assert.isTrue(out.indexOf('case 1:\n\t\t\t\taa(bb);') != -1, 'the statement-position knob coordinates the same way: <$out>');
	}

	public function testNestedSwitchCoordinatesIndependently(): Void {
		// The inner switch's own widest sibling decides for the inner
		// cases; the outer verdict must not leak in (each list resolves
		// its own slots before the outer list reads them).
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
		// The list measures with `WrapList.flatLength`, which descends
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

	public function testKeepIgnoresTheKey(): Void {
		final keep: String = write(
			MIXED_SRC, '{"wrapping": {"maxLineLength": 39}, "sameLine": {"caseSiblings": "anyBreak", "expressionCase": "keep"}}'
		);
		Assert.isTrue(keep.indexOf('case 1: aa(bb);') != -1, 'Keep still preserves the source shape, symmetry or not: <$keep>');
		Assert.isTrue(keep.indexOf('case 2: cc(ddddddddddddddd);') != -1, '<$keep>');
	}

	/**
	 * The key shares a `fitLine` choice and nothing else: under `same`, `next` and `keep` it moves no byte. A label-splice
	 * body writes its slot whatever the policy, so its fixtures are the ones that could break this. Each fixture first shows
	 * it does tell the two values apart under `fitLine`.
	 */
	@:pin('guard')
	public function testTheKeyMovesNothingOutsideFitLine(): Void {
		final cfg: (
			String, String
		) -> String = (policy, siblings) ->
			'{"wrapping": {"maxLineLength": 39}, "sameLine": '
				+ '{"caseSiblings": "$siblings", "caseBody": "$policy", "expressionCase": "$policy"}}';
		for (src in [MIXED_SRC, SPLICE_CASE_SRC, TWO_SPLICE_CASES_SRC]) {
			Assert.notEquals(
				write(src, cfg('fitLine', 'off')), write(src, cfg('fitLine', 'anyBreak')), 'the fixture must discriminate: <$src>'
			);
			for (policy in ['same', 'next', 'keep'])
				Assert.equals(write(src, cfg(policy, 'off')), write(src, cfg(policy, 'anyBreak')), '$policy must ignore the key: <$src>');
		}
	}

	/**
	 * A branch below its label because of a comment does not lead, even when it is also too wide. Its fitting sibling stays on its label.
	 */
	public function testABranchHeldBelowItsLabelByACommentDoesNotLead(): Void {
		final wide: String = ''.lpad('n', 68);
		final cfg: String = '{"wrapping": {"maxLineLength": 60}, "sameLine": {"caseSiblings": "anyBreak", "caseBody": "fitLine", '
			+ '"expressionCase": "fitLine"}}';
		for (branch in ['case 1:\n\t\t\t\t// lead\n\t\t\t\t$wide(bb);', 'case 1: // c\n\t\t\t\taa(bb);']) {
			final src: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n\t\t\t$branch\n\t\t\tcase 2: cc(dd);\n\t\t}\n\t}\n}\n';
			final out: String = write(src, cfg);
			Assert.isTrue(out.indexOf('case 2: cc(dd);') != -1, 'a fitting sibling stays on its label: <$out>');
		}
	}

	public function testDeeplyNestedSwitchesStayLinear(): Void {
		// A slot holds the body in both forms and the output must stay correct with deep nesting: a walker descending
		// both branches would make this fixture's cost double per level.
		final src: String = deepSwitch(15);
		final j: String = '{"wrapping": {"maxLineLength": 140}, "sameLine": {'
			+ '"caseSiblings": "anyBreak", "caseBody": "fitLine", "expressionCase": "fitLine"}}';
		final pass1: String = write(src, j);
		Assert.equals(pass1, write(pass1, j), 'a deeply nested switch must still reach its fixed point in one pass');
		Assert.isTrue(pass1.indexOf('case 3: aa(bb);') != -1, 'the innermost body still fits and stays inline: <$pass1>');
	}

	/** The only over-wide body sits inside a `#if` region, and it still leads. */
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
	 * — so the decision takes the maximum ACROSS all of them and the one
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
	 * `#if` inside `#if`. Under the DEFAULT
	 * `indentation.conditionalPolicy: aligned` a doubly-nested case renders at
	 * the SAME indent as the switch's own, so its width is comparable.
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
	 */
	public function testGlueInsideARegionIsNotATrigger(): Void {
		final out: String = write(GLUED_REGION_SRC, json(140));
		Assert.isTrue(out.indexOf('case 1: (a, b) -> {') != -1, 'the glued body inside the region stays glued: <$out>');
		Assert.isTrue(out.indexOf('case _: gg(hh);') != -1, 'and its plain sibling stays inline: <$out>');
	}

	/**
	 * `#if <open> switch (…) { #else … #end <cases> } }` — the shared case
	 * list of a token-splice switch header. It is a ROOT case list with no
	 * enclosing shared Star, so it shares by itself.
	 */
	@:pin('control')
	@:killer('M-SIBLING-DECIDE-OFF')
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
	 * The count is over slots, not list elements, so the two coordinate like
	 * any pair of siblings.
	 */
	public function testALoneRegionsCasesCoordinateWithEachOther(): Void {
		final out: String = write(LONE_REGION_SRC, json(39));
		Assert.isTrue(out.indexOf('case 1:\n\t\t\t\taa(bb);') != -1, 'the region\'s narrower case must follow its widest: <$out>');
		Assert.isTrue(out.indexOf('case 2:\n\t\t\t\tcc(ddddddddddddddd);') != -1, '<$out>');
	}

	/**
	 * A PATTERN-scope conditional (`case #if js "a" #else "b" #end:`) is a plain `CaseBranch`: the directives render
	 * inline in the flat walk, so the element measures a real width and leads.
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

	public function testKeepIgnoresTheKeyOnAConditionalSwitch(): Void {
		final keep: String = write(
			CONDITIONAL_SRC, '{"wrapping": {"maxLineLength": 39}, "sameLine": {"caseSiblings": "anyBreak", "expressionCase": "keep"}}'
		);
		Assert.isTrue(keep.indexOf('case 1: aa(bb);') != -1, 'Keep preserves the source shape, region or not: <$keep>');
		Assert.isTrue(keep.indexOf('case 2: cc(ddddddddddddddd);') != -1, '<$keep>');
		Assert.isTrue(keep.indexOf('case _: ee(ff);') != -1, '<$keep>');
	}

	/** The value set is closed: `widthOnly`, the trigger nobody chose, is refused and not read as `off`. */
	public function testAnUnknownValueIsRefused(): Void {
		Assert.raises(HaxeFormatConfigLoader.loadHxFormatJson.bind('{"sameLine": {"caseSiblings": "widthOnly"}}'));
	}

	/** The key is off by default: the same switch keeps the per-branch mix, the shape `anyBreak` removes. */
	public function testAnAbsentKeyDecidesPerBranch(): Void {
		final out: String = write(MIXED_SRC, '{"wrapping": {"maxLineLength": 39}, "sameLine": {"expressionCase": "fitLine"}}');
		Assert.isTrue(out.indexOf('case 1: aa(bb);') != -1, 'a fitting sibling stays on its label: <$out>');
		Assert.isTrue(out.indexOf('case 2:\n\t\t\t\tcc(ddddddddddddddd);') != -1, 'only the over-wide body moves: <$out>');
		final off: String = write(
			MIXED_SRC, '{"wrapping": {"maxLineLength": 39}, "sameLine": {"caseSiblings": "off", "expressionCase": "fitLine"}}'
		);
		Assert.equals(out, off, 'the value `off` is the absent key');
	}

	/**
	 * A `switch` opened inside `#if` by shape, not width: a branch below its label for its shape spreads the shared
	 * list, one of the two forms no tree exercises. The width form is `testCondSpliceSwitchOpenCoordinatesItsSharedCaseList`.
	 */
	@:pin('control')
	@:killer('M-SIBLING-DECIDE-OFF')
	public function testCondSpliceSwitchOpenSpreadsByShape(): Void {
		final src: String = 'class M {\n\tfunction f():Void {\n#if utf16\n\t\tfor (c in it(tmp)) {\n\t\t\tswitch (c) {\n#else\n'
			+ '\t\tfor (i in 0...tmp.length) {\n\t\t\tswitch (fast(tmp, i)) {\n#end\n\t\t\t\tcase 1: aa(bb);\n'
			+ '\t\t\t\tcase 2: if (x) y;\n\t\t\t\tcase _:\n\t\t\t\t\ta;\n\t\t\t\t\tb;\n\t\t\t}\n\t\t}\n\t}\n}\n';
		final out: String = write(src, jsonCaseBody(140));
		Assert.isTrue(out.indexOf('case 1:\n\t\t\t\t\taa(bb);') != -1, 'the fitting sibling must follow the multi-statement one: <$out>');
		Assert.isTrue(out.indexOf('case 2:\n') != -1, '<$out>');
		Assert.equals(out, write(out, jsonCaseBody(140)), 'one round trip must land on the fixed point');
	}

	/**
	 * A case unit whose only over-wide part is a threshold-pivot literal must not lead the sibling spread: the next pass
	 * reads that literal back as committed, where the unit measures no flat width and its siblings stay on their labels.
	 * The one fixture exercising the offer: no tree does, and without the offer this fixture alone needs a second pass.
	 */
	@:pin('control')
	@:killer('M-SIBLING-OFFER-UNALIASED')
	public function testPivotCaseUnitDoesNotLeadTheSiblingSpread(): Void {
		final src: String = 'class C {\n\tfunction f(): Candidate {\n\t\treturn switch kind {\n'
			+ '\t\t\tcase Provable: dropped(\'the key binder is never read; iterate the values alone, the loop never reads it\', null);\n'
			+ '\t\t\tcase Keyed:\n\t\t\t\tdropped(\n\t\t\t\t\t\'the key binder is never read; drop it if nothing the loop runs changes the '
			+ 'map, else rename it to a wildcard\',\n\t\t\t\t\t{ iterable: iterable, body: bodySpan }\n\t\t\t\t);\n'
			+ '\t\t\tcase Unprovable: renamed(keyToken, \'the key binder is never read; rename it to a wildcard\');\n\t\t};\n\t}\n}';
		final once: String = write(src, PIVOT_CONFIG);
		Assert.isTrue(
			once.indexOf('\t\t\tcase Provable: dropped(') != -1 && once.indexOf('\t\t\tcase Unprovable: renamed(') != -1,
			'the fitting siblings must stay on their labels:\n<$once>'
		);
		Assert.isTrue(
			once.indexOf('\t\t\tcase Keyed:\n\t\t\t\tdropped(\'the key binder') != -1 && once.indexOf('a wildcard\', {\n') != -1,
			'the pivot unit must break its own literal below its label:\n<$once>'
		);
		Assert.equals(once, write(once, PIVOT_CONFIG), 'one round trip must land on the fixed point');
	}

	/** A glue outcome is not a spread trigger, and turning one into a break must not make it one. */
	public function testGlueTurnedBreakIsNotATrigger(): Void {
		final src: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n\t\t\tcase 1: listedThings.exists(function(subItem) {\n'
			+ '\t\t\t\treturn subItem.kind == ItemData.KIND_SUBSTITUTE;\n\t\t\t});\n\t\t\tcase _: bar();\n\t\t}\n\t}\n}\n';
		final out: String = write(
			src,
			'{"wrapping": {"maxLineLength": 58}, "sameLine": {"caseSiblings": "anyBreak", "caseBody": "fitLine", "ifBody": "fitLine"}}'
		);
		Assert.isTrue(
			out.indexOf('\t\t\tcase 1:\n\t\t\t\tlistedThings.exists(') != -1, 'the glued sibling must really have broken: <$out>'
		);
		Assert.isTrue(out.indexOf('case _: bar();') != -1, 'a fitting sibling must not be dragged down by a glue-turned-break: <$out>');
	}

	private inline function jsonCaseBody(maxLineLength: Int): String {
		return '{"wrapping": {"maxLineLength": $maxLineLength}, "sameLine": {"caseSiblings": "anyBreak", "caseBody": "fitLine"}}';
	}

	private inline function json(maxLineLength: Int, alignInline: Bool = false): String {
		return '{"wrapping": {"maxLineLength": $maxLineLength}, "indentation": {"alignInlineSwitchCaseBody": $alignInline'
			+ '}, "sameLine": {"caseSiblings": "anyBreak", "expressionCase": "fitLine"}}';
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

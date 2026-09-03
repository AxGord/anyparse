package unit.core;

import anyparse.core.Doc;
import anyparse.core.DocMeasure;
import anyparse.core.Renderer;
import utest.Assert;
import utest.Test;

/**
 * The two RENDER-DECISION consumers of `Renderer`'s first-line walk, pinned at
 * the seam they share: the `bgPrefix` flag of
 * `flatTokenWidthFirstLineWithBreak`, which decides what a nested `BodyGroup`
 * contributes to the width of the line it sits on. `true` charges a COMMITTED
 * one its own first-line prefix and ends the line there; `false` defers every
 * one of them (zero width, no line end).
 *
 * EVERY CASE HERE IS GREEN AT BASE BY CONSTRUCTION — this slice changed no
 * renderer behaviour. They are controls over unchanged code, so their evidence
 * is the MUTATION each is paired with. The seven below flip nearly disjoint
 * sets; the last two exist for the vacuity audit, proving that the two
 * deferred-answer assertions and the inline-body control are reachable too. All
 * measured on `a3cc4999`, and the 946-fixture corpus stays at 781/120/43 under
 * every one of them — no corpus fixture guards any of this.
 *
 * Mutations of `Renderer.hx`, and what each one turns red:
 *
 *  1. `flatFirstLineStep`'s `BodyGroup` arm never charges —
 *     `testBlockBodyChargesItsBareBrace`, the `equals(17, …)` assertion of
 *     `testArrowMarkerAdmitsExactlyOneColumn` (the keep-mode literal's walk no
 *     longer stops at the nested body and runs on to 26), and the pre-existing
 *     `WrapFlatSourceFixedPointTest.testCommittedBodyGroupPrefixConvergesOnFirstPass`.
 *  2. `selfBreakingBraceBody`'s `<= 1` becomes `<= 0` —
 *     `testArrowMarkerAdmitsExactlyOneColumn` plus five
 *     `HxArrowBlockBodyOpenSliceTest` cases.
 *  3. The same `<= 1` becomes `<= 2` — `testArrowMarkerAdmitsExactlyOneColumn`
 *     ONLY.
 *  4. The same `<= 1` becomes `<= 1000` — `testArrowMarkerAdmitsExactlyOneColumn`
 *     plus `testKeepModeLiteralBreakingLaterStillBreaks`.
 *  5. `restNodeWidth`'s `flatTokenWidthFirstLineWithBreak(innerDoc, false)`
 *     becomes `true` — `testRestStackDefersACommittedNestedBody` ONLY.
 *  6. `flatFirstLineStep` charges under BOTH accuracies (W17's both-true arm) —
 *     `testRestStackDefersACommittedNestedBody` plus the two DEFERRED-answer
 *     assertions of `testBlockBodyChargesItsBareBrace`.
 *  7. `restNodeWidth`'s `BodyGroup` arm charges unconditionally (its
 *     `prefix.broke` test dropped) — BOTH rest-stack cases here plus four
 *     pre-existing ones (`testGuardLabelFitDoesNotCountBody`,
 *     `testGuardRejoinsSourceBrokenLabelThatFits`,
 *     `testIfChainHeaderFitsBodyDrops`, `testWhileChainHeaderFitsBodyDrops`).
 *
 * Rows 3 and 4 UNDERSTATE what one assertion buys: `isFalse(selfBreakingBraceBody(past))`
 * on a Doc measuring 2 fails for EVERY threshold at or above 2, so it closes the
 * whole slack in one go, and row 2 closes the other side. The threshold is pinned
 * at exactly 1 in both directions.
 *
 * WHY EACH ONE WAS MISSING.
 *
 * The CHARGE itself was already pinned, end-to-end and under one config, by
 * `testCommittedBodyGroupPrefixConvergesOnFirstPass` through the
 * `IfFirstLineExceeds` probe. What had nothing was its SECOND consumer:
 * reverting the charge at `selfBreakingBraceBody`'s call site alone left the
 * suite green and the corpus byte-identical, because a block body measures 0
 * deferred and 1 charged and the threshold `<= 1` admits both. That path cannot
 * be pinned end-to-end at all, so `testBlockBodyChargesItsBareBrace` asserts the
 * two widths themselves — and note what that does NOT cover: which of the two
 * the call site ASKS for is still unpinnable by construction, and stays so after
 * this class.
 *
 * The THRESHOLD had one-sided coverage. `<= 0` flipped five arrow cases, but
 * `<= 2` flipped nothing in the suite or the corpus, and the next threshold
 * sampled above it that moved anything was `<= 1000` — 35 values of slack over a
 * threshold the whole admitted population sits exactly on. Nothing between 3 and
 * 36 was tried; the slack is bounded by those two samples, not swept. The `{a`
 * fixture sits one column past the boundary and closes that side, with the other
 * two conjuncts asserted TRUE on the same Doc so the `false` verdict can only
 * come from the width.
 *
 * `restNodeWidth`'s `false` had nothing in `test/` at all. Its guard was the
 * whole-tree `apq fmt --list` — two files drift when it is flipped,
 * `check/PreferMapType.hx` and `query/LintFixSafePass.hx`, both the very
 * `for (…) if (…) { … }` shape that arm's own comment names — plus a Pony A/B.
 * Both are whole-tree byte oracles: they answer only when some file's layout
 * happens to tip, they name no mechanism, and they go silent the moment the tree
 * is reformatted. The render case below asks the walker its own question.
 */
@:nullSafety(Strict)
@:access(anyparse.core.Renderer)
final class BodyGroupPrefixChargeConsumerTest extends Test {

	public function new(): Void {
		super();
	}

	/**
	 * The value the two accuracies disagree on. A statement block sits behind a
	 * `BodyGroup` that hardlines right after its `{`: charged it reports that
	 * bare `{` and ENDS the line, deferred it reports nothing and the walk runs
	 * on. Both answers reach `selfBreakingBraceBody`'s `<= 1`, which is why
	 * only a direct assertion can pin the charge.
	 */
	public function testBlockBodyChargesItsBareBrace(): Void {
		final block: Doc = blockBody();
		Assert.equals(1, Renderer.flatTokenWidthFirstLine(block));
		Assert.isTrue(Renderer.flatTokenWidthFirstLineWithBreak(block, true).broke);
		Assert.equals(0, Renderer.flatTokenWidthFirstLineWithBreak(block, false).width);
		Assert.isFalse(Renderer.flatTokenWidthFirstLineWithBreak(block, false).broke);
	}

	/**
	 * The arrow-body marker's population is `{`-leading, forced-breaking, and
	 * EXACTLY one column wide on its first line. One column past that and the
	 * body no longer terminates the head line by itself, so the arrow break
	 * must stay — the same reason the keep-mode literal drops out at 17.
	 */
	public function testArrowMarkerAdmitsExactlyOneColumn(): Void {
		Assert.isTrue(Renderer.selfBreakingBraceBody(blockBody()));
		Assert.isTrue(Renderer.selfBreakingBraceBody(selfBreakingLiteral()));
		final past: Doc = oneColumnPastTheThreshold();
		// The other two conjuncts hold on this Doc, so the width is the only
		// thing that can reject it.
		Assert.isTrue(DocMeasure.firstVisibleTextStartsWith(past, '{'.code));
		Assert.isTrue(DocMeasure.hasForcedBreak(past));
		Assert.equals(2, Renderer.flatTokenWidthFirstLine(past));
		Assert.isFalse(Renderer.selfBreakingBraceBody(past));
		final keep: Doc = keepModeLiteral();
		Assert.equals(17, Renderer.flatTokenWidthFirstLine(keep));
		Assert.isFalse(Renderer.selfBreakingBraceBody(keep));
	}

	/**
	 * The rest-of-stack lookahead behind `IfLineExceeds`. The trailing frame is
	 * a cuddled single-statement body (`if (c) for (x in xs) { … }`) whose own
	 * body is a committed block. Deferring reports 0 and the probe keeps the
	 * glued branch; charging reports 16 (` for (x in xs)` plus the nested ` {`)
	 * and terminates the scan, which crosses the threshold and takes the break
	 * branch. The assertion spans both halves — the branch token and the
	 * trailing content that decided it — so neither can be satisfied alone.
	 */
	public function testRestStackDefersACommittedNestedBody(): Void {
		final doc: Doc = Concat([
			IfLineExceeds(10, Text('BROKEN'), Text('glued')),
			cuddledBodyOverACommittedBlock()
		]);
		Assert.equals('glued for (x in xs) {\nuse(x);\n}', Renderer.render(doc, 140));
	}

	/**
	 * Isolation control for the case above: with the nested body INLINE (no
	 * hardline of its own) both accuracies defer it, so the probe keeps its
	 * glued branch under either. Deliberately does NOT flip under the
	 * `false` -> `true` mutation — that is what makes it the bound on which
	 * shapes that mutation can reach. It is still failable, and the audit proved
	 * it: dropping the arm's `prefix.broke` test so it charges unconditionally
	 * turns this case red along with five others.
	 */
	public function testRestStackAlsoDefersAnInlineNestedBody(): Void {
		final inlineBody: Doc = BodyGroup(Concat([Text(' for (x in xs)'), BodyGroup(Text(' use(x);'))]));
		final doc: Doc = Concat([IfLineExceeds(10, Text('BROKEN'), Text('glued')), inlineBody]);
		Assert.equals('glued for (x in xs) use(x);', Renderer.render(doc, 140));
	}

	/** The FLAT side of an arrow-body marker whose body is a multi-statement block. */
	private static function blockBody(): Doc {
		return BodyGroup(Concat([Text('{'), Line('\n'), Text('doIt();'), Line('\n'), Text('}')]));
	}

	/** An object literal whose own wrap cascade already committed to breaking right after its `{`. */
	private static function selfBreakingLiteral(): Doc {
		return Concat([Text('{'), Line('\n'), Text('a: 1'), Line('\n'), Text('}')]);
	}

	/** The same shape with ONE column of content before the hardline — the first Doc past the threshold. */
	private static function oneColumnPastTheThreshold(): Doc {
		return Concat([Text('{'), Text('a'), Line('\n'), Text('b: 1'), Line('\n'), Text('}')]);
	}

	/** A keep-mode literal breaking LATER than its `{`: the hardline belongs to a nested block body. */
	private static function keepModeLiteral(): Doc {
		return Concat([
			Text('{ onDone: () -> '),
			BodyGroup(Concat([Text('{'), Line('\n'), Text('run();'), Line('\n'), Text('}')])),
			Text(', tag: 1 }')
		]);
	}

	/** A cuddled single-statement body whose own body is a committed block — `if (c) for (x in xs) { … }`. */
	private static function cuddledBodyOverACommittedBlock(): Doc {
		return BodyGroup(Concat([
			Text(' for (x in xs)'),
			BodyGroup(Concat([Text(' {'), Line('\n'), Text('use(x);'), Line('\n'), Text('}')]))
		]));
	}

}

package anyparse.format;

import anyparse.core.Doc;
import anyparse.core.DocMeasure;
import anyparse.format.wrap.WrapList;

/**
 * The single `FitLine` body layout emitter.
 *
 * Two writer paths place a construct's body relative to its header under
 * `BodyPolicy.FitLine` — `WriterLowering.buildBodyFitExpr` for a bare-Ref body
 * field and `TriviaTryparseLowering.triviaTryparseCaseWrapExpr` for the
 * `@:tryparse` Star body of a case branch. Both call this function, so the Doc
 * shape has ONE owner: as two hand-written copies they drifted, and the copy that
 * lost the `flatLength == -1` clause made its placement depend on the SOURCE line
 * shape, which cost `fitLine` its idempotence.
 *
 * Two outcomes, chosen by whether the body CAN render on one line:
 *
 *  - `WrapList.flatLength(body) == -1` — the body's Doc commits to a hardline, so
 *    measuring it WHOLE is meaningless because no budget makes it fit. It GLUES to
 *    the header, the answer `BodyPolicy.Same` gives, with an `OptSpace` separator
 *    so a body opening with its own hardline leaves no trailing space; the glue is
 *    still width-gated by `glueLayout`, since the body's FIRST line is a real line.
 *    A caller may refuse the glue outright (`refuseGlue`) and take `breakLayout`
 *    instead — a decision about the body's KIND, not its width, hence the caller's.
 *  - otherwise — `BodyGroup(Nest(cols, [Line, body]))`, and the renderer's
 *    `fitsFlat` picks same-line or next-line-one-deeper from the live column.
 *
 * WHY that branch is load-bearing: `Renderer.fitsFlat` DEFERS a nested `BodyGroup`
 * (its content decides its own layout later, so it must not spend the parent's
 * budget) while `WrapList.flatLength` DESCENDS one. A body whose Doc is a
 * `BodyGroup` around forced-multi-line content therefore measures as nearly EMPTY
 * to `fitsFlat` and would inline, while the same content outside a `BodyGroup`
 * refuses to flatten — and since the writer wraps source-multi-line literals in a
 * `BodyGroup` and single-line ones not, `fitsFlat` alone answers differently for
 * the two source shapes of ONE AST. Asking the descending measure FIRST removes
 * the source shape from the decision, which is what lets a single `fmt` pass reach
 * the `writeRoundTrip(s) == s` fixed point.
 *
 * `nestGluedBody` is the one genuine difference between the two callers, so it is a
 * parameter rather than a second copy: on the glue outcome the body's inner lines
 * may need one extra continuation indent level relative to the header line. The
 * MEASURED outcome does not take the flag — a body that reaches it has no hardline
 * anywhere, so its `Nest` can only apply to breaks the enclosing group introduces.
 */
final class BodyFit {

	/**
	 * `_caseSiblingFlatWidth` sentinel: no sibling coordination — every body decides
	 * for itself. What a case-list Star records when it is not opted in, when its
	 * policy is not `FitLine`, when it holds one element or fewer, or when no element
	 * could have rendered inline at all.
	 */
	public static inline final SIBLING_NONE: Int = -1;

	/**
	 * `_caseSiblingFlatWidth` sentinel: a widest-sibling pre-pass is IN PROGRESS
	 * somewhere above. Suppresses coordination like `SIBLING_NONE`, and additionally
	 * tells every nested case-list Star to skip its OWN pre-pass and pass the marker
	 * further down.
	 *
	 * The suppression has no output consequence, because the pre-pass consumes its
	 * Docs only through `WrapList.flatLength`, which forwards `IfIndentWidthExceeds`
	 * to the FLAT branch — a nested switch's coordination cannot change the width
	 * being measured. Without the marker every nesting level re-measures its whole
	 * subtree, which is the exponential blow-up this sentinel exists to prevent.
	 */
	public static inline final SIBLING_PROBING: Int = -2;

	/**
	 * `_caseSiblingFlatWidth` FORCE channel: a width so large that
	 * `IfIndentWidthExceeds` takes its break branch at every real indent and budget, so
	 * every coordinated body in the group goes below its label.
	 *
	 * It is an ordinary `siblingWidth >= 0`, so `fitLineLayout` needs no arm for it and
	 * the renderer no new ctor. What it encodes is a verdict the emitter reached without
	 * a width COMPARISON: some unit of the group renders below its own label whatever
	 * the budget — a multi-statement body, a single-statement body `caseBodyRefusesFlat`
	 * refuses, a label-splice region whose shared body always sits below the labels it
	 * was split from, or a body with no flat width that `caseBodyControlFlowRoot`
	 * refuses the glue — so the per-switch rule "if one body is below its label, all
	 * are" fires. The trigger set and the shapes it leaves out are both enumerated in
	 * `WriterLowering.caseSiblingWidthProbeExpr`'s doc.
	 */
	public static inline final SIBLING_FORCE_BREAK: Int = 0x0FFFFFF0;

	/** `arrowConstructHeadWidth`'s answer for a body with no construct head of its own. */
	private static inline final NO_CONSTRUCT_HEAD: Int = -1;

	/**
	 * The BREAK shape every `FitLine` outcome falls back to: `body` on the
	 * next line, one indent level deeper than the header.
	 *
	 * Three sites want exactly this Doc — the sibling-coordinated probe's
	 * break branch, `glueLayout`'s over-wide answer, and the control-flow
	 * glue refusal — so it has one owner rather than three literal copies to
	 * keep in step.
	 */
	public static inline function breakLayout(cols: Int, body: Doc): Doc {
		return Doc.Nest(cols, Doc.Concat([Doc.Line('\n'), body]));
	}

	/**
	 * Build the `FitLine` placement Doc for `body` under a header rendered at the
	 * enclosing indent.
	 *
	 * `siblingWidth < 0` (`SIBLING_NONE`, the default) is the per-construct decision
	 * described on the class: measure when the body can render flat, width-gate the
	 * glue when it cannot. `lineWidth` is REQUIRED and comes before it — the glue gate
	 * needs a budget at every call site, and an omitted-by-default width would
	 * silently restore the unmeasured glue this seam exists to remove.
	 *
	 * `siblingWidth >= 0` opts into the SIBLING-COORDINATED decision: the caller passes
	 * ONE width for the whole group and the result is an `IfIndentWidthExceeds` probe
	 * on it, so every sibling — all at the same indent — answers identically. Over the
	 * budget the body goes to the next line one indent deeper and so does every
	 * sibling, including ones that would have fit or glued; within it the probe falls
	 * through to the per-construct decision above.
	 *
	 * TWO CHANNELS reach that width and this function deliberately cannot tell them
	 * apart: the widest sibling's flat width, or `SIBLING_FORCE_BREAK` for a group
	 * holding a unit that sits below its own label at every budget. A GLUED body is not
	 * such a unit — its first line shares the label line — but a coordinated break
	 * still moves it, since it sits inside the probe's break branch like everyone else.
	 *
	 * `refuseGlue` replaces the glue outcome with `breakLayout`, and it is the CALLER's
	 * verdict rather than anything measured here: the case-body path passes it when the
	 * body's single statement is keyword-led control flow, whose continuation lines
	 * (`else if`, `} while`, `catch`) are siblings of its head and so render at the
	 * HEAD's indent when glued, reading as if the statement had left the branch. The
	 * flag cannot reach the MEASURED outcome, so a body that renders flat is untouched.
	 *
	 * Some shapes DO render below their label and still cannot LEAD the group;
	 * `WriterLowering.caseSiblingWidthProbeExpr`'s doc enumerates them. The render-time
	 * one is a glue that `glueLayout` turns into a break — a verdict reached at the LIVE
	 * PEN COLUMN, which no emitter-side walk can see, so the pre-pass never learns it.
	 */
	public static function fitLineLayout(
		cols: Int, body: Doc, nestGluedBody: Bool, lineWidth: Int, siblingWidth: Int = SIBLING_NONE, refuseGlue: Bool = false
	): Doc {
		final flat: Int = WrapList.flatLength(body);
		final own: Doc = if (flat != -1)
			chainStaircase(cols, body, Doc.BodyGroup(Doc.Nest(cols, Doc.Concat([Doc.Line(' '), body]))), lineWidth);
		else if (refuseGlue)
			breakLayout(cols, body);
		else {
			final glued: Doc = Doc.Concat([Doc.OptSpace(' '), body]);
			glueLayout(cols, body, nestGluedBody ? Doc.Nest(cols, glued) : glued, lineWidth);
		}
		return siblingWidth < 0 ? own : Doc.IfIndentWidthExceeds(siblingWidth, lineWidth, breakLayout(cols, body), own);
	}

	/**
	 * `FitLine` for a body that may break only INSIDE a delimiter its OWN head line
	 * opened (`@:fmt(strictFitLineBody(...))`).
	 *
	 * A glued body renders its continuation at the CONTAINER indent, so a head ending
	 * at an OPERAND — an `if` whose branches break, a nested comprehension — lands its
	 * `else`, or its next head, level with the line the container opened and detached
	 * from a head that sits mid-line. That is the whole hazard behind this field flag.
	 * A head ending at an open delimiter cannot reach the container indent at all:
	 * everything below the head belongs to what the head opened.
	 *
	 * `IfNaturalFirstLineFitsOpenDelim` asks both halves at the live pen — the glued
	 * first line must FIT and must END at `(` / `[` / `{` / `->`. The natural walk sees
	 * a nested probe on its flat side, so a chained spine is measured whole at the
	 * OUTERMOST link and the links cannot glue one at a time.
	 *
	 * `keywordLedBody` is the caller's verdict that the body is itself a keyword-led
	 * construct, and it is the second half of the same question: only such a body
	 * carries its continuation inside what its OWN head opened. A value whose head
	 * happens to end at a delimiter — a lambda, a map entry, a nested comprehension —
	 * stacks its own closers under the container's, so it keeps the refusal whatever
	 * its first line looks like.
	 *
	 * A body that renders flat keeps the shared `fitLineLayout` answer; the glue
	 * verdict for a body that cannot is the only thing this function decides.
	 */
	public static function strictFitLineLayout(cols: Int, body: Doc, lineWidth: Int, keywordLedBody: Bool): Doc {
		return if (WrapList.flatLength(body) != -1)
			fitLineLayout(cols, body, false, lineWidth);
		else if (!keywordLedBody || lineWidth <= 0)
			breakLayout(cols, body);
		else
			Doc.IfNaturalFirstLineFitsOpenDelim(lineWidth, breakLayout(cols, body), Doc.Concat([Doc.OptSpace(' '), body]));
	}

	/**
	 * Width answer for the GLUE outcome: `glued` as written when the header line still
	 * fits with the body's first line on it, otherwise `body` on the next line one
	 * indent deeper — the same break shape every other `FitLine` outcome uses.
	 *
	 * The three writer sites that emit a `FitLine` glue all reach it by the same test,
	 * `WrapList.flatLength(body) == -1`, and all three used to stop there, placing a
	 * body that cannot render flat without ever measuring it, so the header line ran
	 * past `maxLineLength` unbounded. This is the one place that answers the width; the
	 * call sites keep only their own glue shape.
	 *
	 * WHAT is measured decides everything, and the two cheap answers are both wrong.
	 * `flatLength` has already said the body carries a hardline, so its full flat width
	 * is not a line width; and its FIRST line, measured statically, counts a condition
	 * or an argument list the renderer will WRAP, which breaks glued shapes that were
	 * never over-wide. `DocMeasure.breakableHead` fails from the other side — it stops
	 * at the first break OPPORTUNITY, the `(` of the body's own condition. The question
	 * needs a speculative render, which is what `IfGluedFirstLineExceeds` runs at the
	 * LIVE PEN COLUMN, since only the renderer knows how wide the header came out.
	 *
	 * The population that MOVES is bodies carrying real content before their first
	 * break: a nested `if (…) {` / `for (…) {` statement, a call whose `{`-lambda
	 * argument breaks. A body that breaks immediately after its own opening `{` is
	 * refused outright however wide the header got — it ends the header line by itself,
	 * so moving it down returns two columns and strands its `{` alone. Same population
	 * and same verdict as `Renderer.selfBreakingBraceBody` gives the arrow-body marker.
	 *
	 * One over-fire is known and accepted: a probe `naturalWidthStructural` resolves on
	 * the FLAT side makes the walk predict a wider header line than the renderer emits,
	 * so a glue can break although it did not have to — same line count, no over-wide
	 * line, and closing it means teaching that walk one more predicate.
	 *
	 * `glued` carries an INVARIANT the render arm does arithmetic on: it must lead with
	 * the one-column glue separator (`OptSpace(' ')`) before `body`, because the
	 * break-side re-measure starts one column left of the body's indent so that
	 * separator lands the body exactly on it. All three callers build
	 * `Concat([OptSpace(' '), …])`; a fourth must too. `lineWidth <= 0` disables the
	 * gate and returns `glued` unchanged — the inert answer for a caller with no width
	 * to spend, which no production config reaches.
	 */
	public static function glueLayout(cols: Int, body: Doc, glued: Doc, lineWidth: Int): Doc {
		return lineWidth <= 0 ? glued : Doc.IfGluedFirstLineExceeds(lineWidth, cols, breakLayout(cols, body), glued);
	}

	/**
	 * The width of the construct head an arrow-lambda body leads with, or
	 * `NO_CONSTRUCT_HEAD` when it has none.
	 *
	 * The `@:fmt(arrowBodyLineWrap)` marker already carries a break-after-`->` layout
	 * and a render-time probe to reach it, but that probe measures FLAT WIDTH, and one
	 * construct shape is invisible to every flat measure: a plain `if` (no `else`)
	 * whose body is a `{}`-block. Its condition and body sit inside the
	 * construct-level `BodyGroup` that `WriterLowering`'s cond-fit group emits, and
	 * `DocMeasure.flatTokenWidthStep` defers a `BodyGroup` to width 0, so the whole
	 * `if (…) { … }` reports only its `if (` where the same shape written as a `for`
	 * reports its true width. The probe can then never fire for it: the body glues to
	 * the header line however wide its own head is, and the `if`'s condition breaks
	 * INSIDE the arrow head, leaving a first line that ends on a bare `if (`.
	 *
	 * Re-tagging the `BodyGroup` as a `Group` is the fix for a HARDLINE-FREE body; a
	 * block body carries hardlines, so re-tagging it would change the render and not
	 * just the measure. Making the width visible to the CALL cascade instead is the
	 * other wrong answer: the call then opens and the body moves twice, relocating the
	 * overflow rather than removing it. What is left is to hand the marker's own probe
	 * an honest width — see `arrowGlueThreshold`.
	 *
	 * THREE refusals:
	 *
	 * - a body that CAN render flat (`flatLength != -1`) has no forced break, so its
	 *   first line IS its whole width and the existing probe already measures it;
	 * - a `{}`-BLOCK body ends the header line by itself, so moving it down strands
	 *   its brace and buys nothing. That population belongs to
	 *   `Renderer.selfBreakingBraceBody`, which reads the marker's FLAT side and must
	 *   keep seeing exactly what it saw before — hence a refusal here rather than a
	 *   probe the renderer would resolve;
	 * - a body whose transparent first line is no WIDER than its flat width hides
	 *   nothing behind a deferral, so there is no correction to make. This is what
	 *   keeps the measure off call-bodied arrows: a call whose argument is a
	 *   `{`-lambda also cannot render flat and also hides content behind a
	 *   `BodyGroup`, but its transparent first line stops at that lambda's `{` and
	 *   comes out SHORTER than the flat width, which counts the arguments past it.
	 *   Without this test such arrows re-glue shapes that were correctly broken.
	 */
	public static function arrowConstructHeadWidth(body: Doc): Int {
		if (WrapList.flatLength(body) != -1) return NO_CONSTRUCT_HEAD;
		if (DocMeasure.firstVisibleTextStartsWith(body, '{'.code) && DocMeasure.hasForcedBreak(body)) return NO_CONSTRUCT_HEAD;
		final head: Int = DocMeasure.flatFirstLineWidthThroughBodyGroup(body);
		return head > DocMeasure.flatTokenWidth(body) ? head : NO_CONSTRUCT_HEAD;
	}

	/**
	 * The `n` the arrow-body markers `IfResidualLineExceeds` must be given so that its
	 * `col + flatTokenWidth(body) + rest >= n` test measures the bodys CONSTRUCT HEAD instead of
	 * the width the `BodyGroup` deferral hid from it.
	 *
	 * The probes own arithmetic is right — it is the only place that knows the pen column the
	 * body would glue to, and its rest-of-stack term is load-bearing. Only the width is wrong.
	 * Both the honest head width and the width the probe WILL measure are static, column-
	 * independent quantities, so their difference folds into the threshold at emit time:
	 * `col + flat + rest >= lineWidth - (head - flat)` is exactly `col + head + rest >=
	 * lineWidth`.
	 *
	 * The correction is one-directional by construction: `arrowConstructHeadWidth` returns a
	 * head only when it EXCEEDS the flat width, so the threshold can only come DOWN, and the
	 * probe can only start firing where it was blind — never stop firing where it already
	 * worked. Without a head there is nothing to correct and `lineWidth` comes back unchanged,
	 * which keeps every other arrow bodys probe byte-identical.
	 */
	public static function arrowGlueThreshold(body: Doc, lineWidth: Int): Int {
		final head: Int = arrowConstructHeadWidth(body);
		return head == NO_CONSTRUCT_HEAD ? lineWidth : lineWidth - (head - DocMeasure.flatTokenWidth(body));
	}

	/**
	 * The BREAK-side answer for a construct-group `FitLine` body that CAN render
	 * flat (`flatLength >= 0`) but did not fit on the header line.
	 *
	 * Until this seam the answer was unconditional: the body went to the next
	 * line one indent deeper, and a body too wide for THAT line broke again
	 * inside itself — paying a line and an indent level for nothing, since the
	 * shape that finally rendered opened with a delimiter that would have fitted
	 * beside the header (`if (c)\n\t({\n\t\tfield…` where `if (c) ({\n\tfield…`
	 * says the same thing two columns and one line cheaper).
	 *
	 * The discriminator is whether the next line would have RESCUED the body:
	 * `flatWidth` measured at the continuation indent (`cols` deeper than the
	 * header's own indent, which only the renderer knows). It fits there — the
	 * body earns its own line, exactly as before. It does not — no line saves
	 * it, so glue and let the body break inside itself, still width-gated by
	 * `glueLayout` so the header line itself cannot run over.
	 *
	 * `Doc.IfArrowContinuationFits` is the continuation-indent probe; its name
	 * records its first consumer (an arrow signature), its semantic is the
	 * general "does this flat width fit one level deeper" question this seam
	 * asks. `n` is `lineWidth + 1` because the probe tests strict `<`.
	 */
	public static function continuationRescuesBody(cols: Int, body: Doc, glued: Doc, flatWidth: Int, lineWidth: Int): Doc {
		return Doc.IfArrowContinuationFits(
			cols, flatWidth, lineWidth + 1, glueLayout(cols, body, pinParenGlued(glued) ?? glued, lineWidth), breakLayout(cols, body)
		);
	}

	/**
	 * The BREAK-side answer for an ARROW-LAMBDA body: the sister of
	 * `continuationRescuesBody` for the one other placement that puts a body
	 * after a header token rather than under it.
	 *
	 * The arrow's own probe has already found that the line carrying
	 * `params -> body` overflows; this decides what that costs. The body fits
	 * one level deeper — it takes the next line, as it always did. It does not
	 * — the next line rescues nothing, so the body stays glued after the `->`
	 * and breaks inside itself, saving a line and an indent level.
	 *
	 * SCOPED to a body that IS an expression paren (`m -> ({ … })`), i.e. one
	 * `pinParenGlued` recognises. Widening it to every arrow body reads WORSE:
	 * an `if`-expression body glues its head and then explodes its own
	 * condition at the deeper column, and a chain body trades one shape for
	 * another with no line saved. The paren body is
	 * the population where the glue provably pays — it breaks at its own `{`
	 * either way, so the delimiter costs nothing beside the arrow while a whole
	 * line and indent level below it do.
	 *
	 * No `glueLayout` width gate here, unlike the construct-body sister: the
	 * separator before an arrow body is a real emitted token rather than the
	 * `OptSpace` that gate does arithmetic on, and the arrow's own
	 * `IfResidualLineExceeds` has already asked the width question for this
	 * line. A glued body whose first line still overflows would overflow on
	 * the next line too — that is what `flatWidth` not fitting MEANS — so the
	 * glue is never the worse of the two.
	 */
	public static function continuationRescuesArrowBody(cols: Int, body: Doc, flatWidth: Int, lineWidth: Int): Doc {
		final pinned: Null<Doc> = pinParenGlued(body);
		return pinned == null
			? breakLayout(cols, body)
			: Doc.IfArrowContinuationFits(cols, flatWidth, lineWidth + 1, pinned, breakLayout(cols, body));
	}

	/**
	 * The chained-`FitLine` staircase gate: a control-flow construct whose `FitLine`
	 * body is ANOTHER such construct that in turn carries one — three or more links —
	 * glues onto ONE line only when the whole chain fits there; otherwise every link
	 * but the last takes its own line.
	 *
	 * Without it each link answers for itself with the next link's body DEFERRED,
	 * since `Renderer.fitsFlat` will not spend a parent's budget on a nested
	 * `BodyGroup`: the chain glues link by link until some link's OWN content
	 * overflows, and that link then pays at the deepest column in the chain by
	 * wrapping its CONDITION.
	 *
	 * `sameLine` is the caller's own same-line layout, returned UNCHANGED for every
	 * shape the gate does not claim, so a two-link chain keeps the head-fit glue it
	 * has always had. The gate is NOT statement-position only — a brace-less FUNCTION
	 * body reaches it through `fitLineLayout` and does not tear, because that two-link
	 * guard refuses the chain — so what differs is the enclosing site, not the
	 * position class.
	 *
	 * The threshold is arithmetic rather than a second measurer: `Doc.IfLineExceeds`
	 * measures with `flatTokenWidth`, which defers the very `BodyGroup`s this gate
	 * exists to charge, and both widths are static and column-independent, so their
	 * difference folds into `n` at emit time — the same correction
	 * `arrowGlueThreshold` makes. Two things keep that boundary exact: `charged`
	 * EXCLUDES the leading glue space, so a line landing ON the limit fits; and the
	 * sibling `WrapList` probe's explicit `lineWidth + 1` must NOT be copied here,
	 * since its measured doc contains the separator this one does not.
	 *
	 * INVARIANT: `n` is computed at EMIT time from `flatTokenWidth(sameLine)`, so no
	 * post-pass may rewrite the flat branch in a way that changes that width.
	 * `WrapList.groupifyInlineBodies` is exactly such a pass and carries an
	 * `IfLineExceeds` through untouched; whether it can reach this gate is UNMEASURED,
	 * and `arrowGlueThreshold` shares the exposure.
	 *
	 * `lineWidth <= 0` returns `sameLine` unchanged, the inert answer for a caller
	 * with no width to spend. `docs/decisions.md` records the refused alternative of
	 * gating the whole `flat != -1` arm on the body's honest full flat width.
	 */
	public static function chainStaircase(cols: Int, body: Doc, sameLine: Doc, lineWidth: Int): Doc {
		if (lineWidth <= 0) return sameLine;
		final second: Null<Doc> = chainBodyInner(body);
		if (second == null || chainBodyInner(second) == null) return sameLine;
		final charged: Int = DocMeasure.flatFirstLineWidthThroughBodyGroup(body);
		final n: Int = lineWidth + DocMeasure.flatTokenWidth(sameLine) - charged;
		return Doc.IfLineExceeds(n, Doc.Nest(cols, Doc.Concat([Doc.Line('\n'), forceChainBreaks(body)])), sameLine);
	}

	/**
	 * Pin a body that IS an expression paren to its GLUED delimiters: `({` on
	 * the header line, `})` closing the body, never the opened
	 * `(` / newline / `{` shape.
	 *
	 * The paren's own emitter offers both through an `IfFullLineExceeds` whose
	 * width question — "can the inner be ONE fitting line if I open?" — is asked
	 * at the paren's frame indent. Glued to a header line, that frame sits one
	 * level shallower than where the open shape would actually land the inner,
	 * so the paren answers yes for an inner that then breaks anyway, and the
	 * body renders as `if (…) (` + `{` + fields + `}` + `)`: two delimiter
	 * lines bought for nothing.
	 *
	 * Correcting the paren's own measure would be the same edit for every
	 * expression paren in the language, and the shape it changes is one the
	 * corpus pins in operand position (`a || (b && c)` opens its paren there,
	 * and should). So the answer is not a stricter shared gate but a pin at the
	 * ONE position that knows the paren is already committed to the header
	 * line — this one. Everything else keeps the emitter's own verdict.
	 *
	 * Only the collapse-CANDIDATE cascade is pinned (an `IfFullLineExceeds`
	 * whose break shape carries a `CollapseProbe` — what the expression-paren
	 * emitter builds); any other Doc is returned untouched, so a body that is
	 * not a paren, or a paren emitted through the condition / chain arms, is
	 * unaffected. Wrappers the glue shape adds around the body (`Concat` head,
	 * `Nest`, `Group`) are rebuilt around the pinned inner rather than
	 * descended past, so no indentation is lost.
	 */
	private static function pinParenGlued(d: Doc): Null<Doc> {
		switch d {
			case Doc.IfFullLineExceeds(_, brk, fl) if (carriesCollapseProbe(brk)):
				return fl;
			case Doc.Nest(n, inner):
				final pinned: Null<Doc> = pinParenGlued(inner);
				return pinned == null ? null : Doc.Nest(n, pinned);
			case Doc.Group(inner):
				final pinned: Null<Doc> = pinParenGlued(inner);
				return pinned == null ? null : Doc.Group(pinned);
			case Doc.Concat(items) if (items.length > 0):
				final pinned: Null<Doc> = pinParenGlued(items[items.length - 1]);
				return pinned == null ? null : Doc.Concat(items.slice(0, items.length - 1).concat([pinned]));
			case _:
				return null;
		}
	}

	/** Does `d` hold a `CollapseProbe` — the marker the expression-paren emitter puts in its OPEN shape? */
	private static function carriesCollapseProbe(d: Doc): Bool {
		switch d {
			case Doc.CollapseProbe(_):
				return true;
			case Doc.Concat(items):
				for (it in items) if (carriesCollapseProbe(it)) return true;
				return false;
			case Doc.Nest(_, inner), Doc.Group(inner), Doc.BodyGroup(inner), Doc.GroupWithRestProbe(inner), Doc.Flatten(inner),
				Doc.HardFlatten(inner), Doc.WrapBoundary(inner):
				return carriesCollapseProbe(inner);
			case _:
				return false;
		}
	}

	/**
	 * The body a `FitLine` construct places on its own header line, or `null` when `d`
	 * is not such a construct — the chain-link test.
	 *
	 * Both writer paths that emit a measured `FitLine` body land on the same
	 * signature: a `BodyGroup` — the body-level one `fitLineLayout` builds, or the
	 * construct-level one `WriterLowering` splices around condition plus body when a
	 * `conditionWrapping` cascade is configured — whose TAIL is
	 * `Nest(cols, Concat([Line(' '), body]))`.
	 *
	 * It is a SHAPE test, not an identity test, and the obvious uniqueness claim is
	 * FALSE: `WriterLowering.valueIfGapExpr` emits the same `Nest` for a value-`if`
	 * gap under `softGap`. What keeps the classifier honest is the POSITION plus the
	 * two-deep requirement — the node must be the tail of a construct's trailing
	 * `BodyGroup` AND hold another such node — and a sweep over the fork corpus, this
	 * tree and Pony under both of its configs, in which the only shapes the gate moved
	 * were control-flow chains. A false positive is a latent hazard rather than an
	 * observed one; tagging the gate's own probe would remove it, at the cost of a
	 * `Doc` ctor. The same reading applies to the `IfLineExceeds` arms below: the two
	 * in the REWRITE twins replace the matched node with its break branch, so a probe
	 * from another emitter landing on a link's tail path would have its own width
	 * decision overwritten.
	 *
	 * Deliberately narrow in two directions, both conservative: a body that cannot
	 * render flat reaches `glueLayout` and carries an `IfGluedFirstLineExceeds`
	 * instead, and a body under `opt.fitLineBodyGlue` carries an `IfBreak` — neither
	 * answers here, so a chain through one of them keeps its current layout.
	 */
	private static function chainBodyInner(d: Doc): Null<Doc> {
		final group: Null<Doc> = tailBodyGroup(d);
		return group == null ? null : tailSlotInner(group);
	}

	/**
	 * The contents of the `BodyGroup` that carries the tail construct's body,
	 * or `null` when `d` has none.
	 *
	 * A construct's Doc is a `Concat` of its keyword, its header and one
	 * `BodyGroup` — the body-level one when the construct has no
	 * `conditionWrapping` cascade, the construct-level one (header AND body
	 * inside it) when it has. Both sit at the tail, sometimes behind an `Empty`
	 * an absent optional field left there, so the walk skips those and never
	 * descends anything else: an earlier `BodyGroup` in the same `Concat`
	 * belongs to a sibling, not to this construct's body.
	 */
	private static function tailBodyGroup(d: Doc): Null<Doc> {
		switch d {
			case Doc.BodyGroup(inner):
				return inner;
			// A link this gate has ALREADY claimed carries its own probe WHERE
			// its body group was; read through the same-line branch so a chain
			// one link longer still classifies every link below it, and
			// staircases as one shape instead of gluing its top two links.
			case Doc.IfLineExceeds(_, _, fl):
				return tailBodyGroup(fl);
			case Doc.Concat(items):
				final i: Int = lastNonEmptyIdx(items);
				return i < 0 ? null : tailBodyGroup(items[i]);
			case _:
				return null;
		}
	}

	/** Index of the last element of `items` that is not an `Empty` placeholder, or `-1`. */
	private static function lastNonEmptyIdx(items: Array<Doc>): Int {
		var i: Int = items.length;
		while (--i >= 0) switch items[i] {
			case Doc.Empty:
			case _:
				return i;
		}
		return -1;
	}

	/** The `Line(' ')`-led body slot at the tail of `d`, unwrapped to its body, or `null`. */
	private static function tailSlotInner(d: Doc): Null<Doc> {
		switch d {
			case Doc.Nest(_, Doc.Concat(items)) if (items.length == 2 && isGlueSeparator(items[0])):
				return items[1];
			// A link this gate has ALREADY claimed carries its own probe in the
			// slot's place; read through the same-line branch so a chain one
			// link longer still classifies every link below it.
			case Doc.IfLineExceeds(_, _, fl):
				return tailSlotInner(fl);
			case Doc.Concat(items):
				final i: Int = lastNonEmptyIdx(items);
				return i < 0 ? null : tailSlotInner(items[i]);
			case _:
				return null;
		}
	}

	/** Is `d` the one-space soft `Line` a `FitLine` body slot leads with? */
	private static function isGlueSeparator(d: Doc): Bool {
		return switch d {
			case Doc.Line(' '): true;
			case _: false;
		};
	}

	/**
	 * Rebuild `d` — a chain link BELOW the one that refused to glue — with its
	 * own body forced onto the next line, recursively.
	 *
	 * The recursion stops one link short of the bottom on purpose: the LAST
	 * link's body is not another construct, so nothing about it forces a
	 * staircase and it keeps its own `FitLine` answer
	 * (`if (c) return true;` stays on one line under the two links above it).
	 * That is the fork's `_forceFitLineNext` cascade, which pushes a link into
	 * the forced set only while `isChainBodyKwd(body.body)` still holds.
	 */
	private static function forceChainBreaks(d: Doc): Doc {
		final rebuilt: Null<Doc> = forceTailBodyGroup(d);
		// `null` is the CASCADE'S STOPPING CONDITION, not a failure — and it was
		// measured, not assumed: a review argued the two walks are arm-for-arm
		// equivalent so `rebuilt` is provably non-null, a `throw` here proved
		// otherwise on the very first fixture. `chainBodyInner(d) != null` says
		// only that `d` HAS a body slot; `forceTailBodyGroup` additionally
		// declines a slot whose inner is not itself a link, which is exactly the
		// deepest link. Returning `d` unchanged there is what lets that link keep
		// its own `FitLine` answer.
		return rebuilt ?? d;
	}

	/** `tailBodyGroup`'s rewriting twin: rebuild `d` around a forced body slot, or `null`. */
	private static function forceTailBodyGroup(d: Doc): Null<Doc> {
		switch d {
			case Doc.BodyGroup(inner):
				final rebuilt: Null<Doc> = forceTailSlot(inner);
				return rebuilt == null ? null : Doc.BodyGroup(rebuilt);
			// The forced form of a link that already carries this gate IS its
			// own break branch — the staircase it built for everything below.
			case Doc.IfLineExceeds(_, brk, fl) if (tailBodyGroup(fl) != null):
				return brk;
			case Doc.Concat(items):
				return rebuiltTail(items, forceTailBodyGroup);
			case _:
				return null;
		}
	}

	/**
	 * Rebuild `items` with `f` applied to its last non-`Empty` element, or `null`
	 * when there is no such element or `f` declines it.
	 *
	 * The two rewriting twins differ only in which walk they recurse with, so the
	 * `Concat` arm is one helper taking that walk as its argument rather than two
	 * copies to keep in step. Trailing `Empty` placeholders survive: the search
	 * SKIPS them, the rebuild writes back at the index the search returned, and
	 * `copy()` carries everything else through untouched.
	 */
	public static function rebuiltTail(items: Array<Doc>, f: Doc -> Null<Doc>): Null<Doc> {
		final i: Int = lastNonEmptyIdx(items);
		if (i < 0) return null;
		final rebuilt: Null<Doc> = f(items[i]);
		if (rebuilt == null) return null;
		final copy: Array<Doc> = items.copy();
		copy[i] = rebuilt;
		return Doc.Concat(copy);
	}

	/**
	 * Rebuild the tail body slot of `d` with a hardline separator, or `null`
	 * when there is no slot to force — including the case where the slot holds
	 * a plain statement rather than another chain link.
	 */
	private static function forceTailSlot(d: Doc): Null<Doc> {
		switch d {
			case Doc.Nest(n, Doc.Concat(items)) if (items.length == 2 && isGlueSeparator(items[0])):
				return chainBodyInner(items[1]) == null ? null : Doc.Nest(n, Doc.Concat([Doc.Line('\n'), forceChainBreaks(items[1])]));
			// The forced form of a link that already carries this gate IS its
			// own break branch — the staircase it built for everything below.
			case Doc.IfLineExceeds(_, brk, fl) if (tailSlotInner(fl) != null):
				return brk;
			case Doc.Concat(items):
				return rebuiltTail(items, forceTailSlot);
			case _:
				return null;
		}
	}

}

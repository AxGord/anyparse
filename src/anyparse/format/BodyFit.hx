package anyparse.format;

import anyparse.core.Doc;
import anyparse.format.wrap.WrapList;

/**
 * The single `FitLine` body layout emitter (ω-case-body-fitline-shared).
 *
 * Two writer paths place a construct's body relative to its header under
 * `BodyPolicy.FitLine`: `WriterLowering.buildBodyFitExpr` for a bare-Ref
 * body field (`return expr;`, `if (c) body`, `for (…) body`) and
 * `WriterLowering.triviaTryparseCaseWrapExpr` for the `@:tryparse` Star
 * body of `HxCaseBranch.body` / `HxDefaultBranch.stmts`. They shipped as
 * two hand-written copies of the same Doc shape, and the copies drifted:
 * the case-path copy lost the `flatLength == -1` clause, which made its
 * placement depend on the SOURCE line shape and cost `fitLine` its
 * idempotence. Both now call this function, so the shape has one owner.
 *
 * Two outcomes, chosen by whether the body CAN render on one line:
 *
 *  - `WrapList.flatLength(body) == -1` — the body's Doc commits to a
 *    hardline (a `{ … }` block, a wrap cascade that refuses one line, a
 *    source-multi-line literal the emitter keeps broken). Measuring it
 *    WHOLE is meaningless: no budget makes it fit. It GLUES to the header,
 *    the same answer `BodyPolicy.Same` gives, with an `OptSpace` separator
 *    so a body that opens with its own hardline does not leave a trailing
 *    space behind — but the glue is width-gated by `glueLayout`, since the
 *    body's FIRST line is a real line and does have to fit.
 *  - otherwise — `BodyGroup(Nest(cols, [Line, body]))`. The renderer's
 *    `fitsFlat` sees the live column (the header is already emitted) plus
 *    the body's flat width and picks same-line or next-line-one-deeper.
 *
 * WHY the two measures differ, and why the branch above is load-bearing:
 * `Renderer.fitsFlat` DEFERS a nested `BodyGroup` (its content decides
 * its own layout later, so it must not spend the parent's budget), while
 * `WrapList.flatLength` DESCENDS one. A body whose Doc is a `BodyGroup`
 * around forced-multi-line content therefore measures as nearly EMPTY to
 * `fitsFlat` — it would "fit" and inline — while an equivalent body whose
 * content sits outside a `BodyGroup` refuses to flatten. Since the writer
 * wraps source-multi-line literals in a `BodyGroup` and single-line ones
 * not, `fitsFlat` alone answers differently for the two source shapes of
 * ONE AST: format once and the body breaks, format the result again and
 * it re-joins. Asking the descending measure FIRST removes the source
 * shape from the decision, which is what makes a single `fmt` pass reach
 * the `writeRoundTrip(s) == s` fixed point.
 *
 * `nestGluedBody` is the one genuine difference between the two callers,
 * so it is a parameter rather than a second copy. On the glue outcome the
 * body's own inner lines may need a `+1` continuation indent relative to
 * the header line. The case path wants it (unless
 * `alignInlineSwitchCaseBody` says the body's container already indents
 * relative to the case line); the bare-Ref path has never emitted it and
 * stays byte-identical with `false`. The measured outcome does not take
 * the flag: a body that reaches it has NO hardline anywhere (that is what
 * `flatLength >= 0` means), so its `Nest` can only ever apply to breaks
 * the enclosing group itself introduces.
 */
final class BodyFit {

	/**
	 * `_caseSiblingFlatWidth` sentinel: no sibling coordination — every body
	 * decides for itself, exactly as before ω-case-sibling-symmetry. What a
	 * case-list Star records when it is not opted in, when its policy is not
	 * `FitLine`, when it holds one element or fewer, or when no element could
	 * have rendered inline at all.
	 */
	public static inline final SIBLING_NONE: Int = -1;

	/**
	 * `_caseSiblingFlatWidth` sentinel: a widest-sibling pre-pass is IN
	 * PROGRESS somewhere above (ω-case-sym-linear). Suppresses coordination
	 * like `SIBLING_NONE`, and additionally tells every nested case-list Star
	 * to skip its OWN pre-pass and pass the marker further down.
	 *
	 * The suppression has no output consequence because the pre-pass consumes
	 * its Docs only through `WrapList.flatLength`, which forwards
	 * `IfIndentWidthExceeds` to the FLAT branch — a nested switch's
	 * coordination cannot change the width being measured. Without the marker
	 * every nesting level re-measures its whole subtree, which is the
	 * 2^depth blow-up this sentinel exists to prevent.
	 */
	public static inline final SIBLING_PROBING: Int = -2;

	/**
	 * Build the `FitLine` placement Doc for `body` under a header rendered at
	 * the enclosing indent.
	 *
	 * `siblingWidth < 0` (`SIBLING_NONE`, the default) is the per-construct
	 * decision described on the class: measure when the body can render flat,
	 * width-gate the glue when it cannot. `lineWidth` is REQUIRED and comes
	 * before it — the glue gate needs a budget at every call site, and an
	 * omitted-by-default width would silently restore the unmeasured glue this
	 * seam exists to remove.
	 *
	 * `siblingWidth >= 0` opts into the SIBLING-COORDINATED decision
	 * (ω-case-sibling-symmetry). The caller has measured every sibling of this
	 * body's group and passes the WIDEST one's flat width; the result is an
	 * `IfIndentWidthExceeds` probe on that width, so every sibling — which
	 * renders at the same indent — answers identically. Exceeds the budget:
	 * the body goes to the next line one indent deeper, and so does every
	 * sibling, including ones that would have fit and ones that would have
	 * glued. Fits: the probe falls through to the per-construct decision above,
	 * which picks the inline shape for every MEASURED sibling (each one's own
	 * width is `<= siblingWidth`).
	 *
	 * GLUE outcomes sit outside the coordinated set in one direction only, and
	 * that asymmetry is deliberate. A coordinated break still moves them (they
	 * are inside the probe's break branch like everyone else), but a glue that
	 * `glueLayout` turns into a break does NOT move its siblings: the widest-
	 * sibling pre-pass consumes bodies through `WrapList.flatLength`, which
	 * answers `-1` for a glued body, so a glue never raises the maximum and
	 * never triggers the coordination. Pinned by
	 * `HxGlueWidthSliceTest.testGlueTurnedBreakIsNotASiblingSymmetryTrigger`.
	 */
	public static function fitLineLayout(cols: Int, body: Doc, nestGluedBody: Bool, lineWidth: Int, siblingWidth: Int = SIBLING_NONE): Doc {
		final own: Doc = if (WrapList.flatLength(body) == -1) {
			final glued: Doc = Doc.Concat([Doc.OptSpace(' '), body]);
			glueLayout(cols, body, nestGluedBody ? Doc.Nest(cols, glued) : glued, lineWidth);
		}
		else
			Doc.BodyGroup(Doc.Nest(cols, Doc.Concat([Doc.Line(' '), body])));
		return siblingWidth < 0
			? own
			: Doc.IfIndentWidthExceeds(siblingWidth, lineWidth, Doc.Nest(cols, Doc.Concat([Doc.Line('\n'), body])), own);
	}

	/**
	 * Width answer for the GLUE outcome (ω-glue-width): `glued` as written when
	 * the header line still fits with the body's first line on it, otherwise
	 * `body` on the next line one indent deeper — the same break shape every
	 * other `FitLine` outcome uses.
	 *
	 * The three writer sites that emit a `FitLine` glue (`fitLineLayout` above;
	 * `WriterLowering.buildBodyFitExpr`'s construct-group arm for if/for/while
	 * bodies and its single-line-flag arm for `return`-style bodies) all reach
	 * the glue by the same test, `WrapList.flatLength(body) == -1`, and all
	 * three used to stop there — a body that cannot render flat was placed
	 * without ever being measured, so the header line ran past `maxLineLength`
	 * unbounded (216 columns measured at a limit of 140). This function is the
	 * one place that answers it; the call sites keep only their own glue shape.
	 *
	 * WHAT is measured decides everything, and the two cheap answers are both
	 * wrong. `flatLength` has already said the body carries a hardline, so its
	 * full flat width is not a line width; and its FIRST line, measured
	 * statically, counts a condition or an argument list that the renderer will
	 * WRAP — over the two corpora that broke 11 files whose glued shape was
	 * never over-wide, most of them regressions. `DocMeasure.breakableHead`
	 * fails from the other side: it stops at the first break OPPORTUNITY, which
	 * for a construct-group body is the `(` of its own condition, so it measures
	 * 5 columns for the very site this slice exists to fix. What the question
	 * actually needs is a speculative render, which is what
	 * `IfGluedFirstLineExceeds` runs — at the LIVE PEN COLUMN, since the header
	 * is emitted by the caller and only the renderer knows how wide it came out.
	 *
	 * The population that MOVES is bodies carrying real content before their
	 * first break: a nested `if (…) {` / `for (…) {` statement, a call whose
	 * `{`-lambda argument breaks. A body that breaks immediately after its own
	 * opening `{` — a statement block, a `{ … }` literal already committed to
	 * breaking — is refused outright, however wide the header got: it ends the
	 * header line by itself, so moving it down returns two columns and strands
	 * its `{` on a line of its own. Same population and same verdict as
	 * `Renderer.selfBreakingBraceBody` gives the arrow-body marker.
	 *
	 * KNOWN over-fire, one site in the two-corpus sweep
	 * (`editor/pitch/PitchArea.hx` `updatePlayerNamesForObjects`): the body is a
	 * call whose sole argument is an array comprehension, and the comprehension
	 * opens its bracket through a probe that the natural walk resolves on the
	 * FLAT side (see the ctor doc's residual note). The walk therefore predicts
	 * `…([ for (x in xs)` on the header line where the renderer emits `…([`, and
	 * the glue breaks although it did not have to. The result is the same line
	 * count and no over-wide line, so it is a wash rather than a regression.
	 * The probe in question is an `IfFirstLineExceeds`, which
	 * `naturalWidthStructural` has no opt-in for — `resolveOpenDelim` covers
	 * only `IfNaturalFirstLineFitsOpenDelim` — so closing it means teaching
	 * that walker a real predicate for one more probe, in a walk three other
	 * consumers share.
	 *
	 * `glued` carries an INVARIANT the render arm does arithmetic on: it must
	 * lead with the one-column glue separator (`OptSpace(' ')`) before `body`,
	 * because the break-side re-measure starts one column left of the body's
	 * indent so that separator lands the body exactly on it. All three callers
	 * build `Concat([OptSpace(' '), …])`; a fourth must too.
	 *
	 * `lineWidth <= 0` disables the gate and returns `glued` unchanged; no
	 * production config reaches it (`WriteOptions.lineWidth` is always the
	 * positive `maxLineLength`), it is the inert answer for a caller that has no
	 * width to spend.
	 */
	public static function glueLayout(cols: Int, body: Doc, glued: Doc, lineWidth: Int): Doc {
		return lineWidth <= 0
			? glued
			: Doc.IfGluedFirstLineExceeds(lineWidth, cols, Doc.Nest(cols, Doc.Concat([Doc.Line('\n'), body])), glued);
	}

}

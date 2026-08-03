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
 *    source-multi-line literal the emitter keeps broken). Measuring it is
 *    meaningless: no budget makes it fit. It GLUES to the header, the
 *    same answer `BodyPolicy.Same` gives, with an `OptSpace` separator so
 *    a body that opens with its own hardline does not leave a trailing
 *    space behind.
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
	 * `siblingWidth < 0` (the default) is the per-construct decision described
	 * on the class: measure when the body can render flat, glue when it
	 * cannot.
	 *
	 * `siblingWidth >= 0` opts into the SIBLING-COORDINATED decision
	 * (ω-case-sibling-symmetry). The caller has measured every sibling of this
	 * body's group and passes the WIDEST one's flat width; the result is an
	 * `IfIndentWidthExceeds` probe on that width, so every sibling — which
	 * renders at the same indent — answers identically. Exceeds the budget:
	 * the body goes to the next line one indent deeper, and so does every
	 * sibling, including ones that would have fit and ones that would have
	 * glued. Fits: the probe falls through to the per-construct decision
	 * above, which by construction then picks the inline shape for every
	 * sibling (each sibling's own width is `<= siblingWidth`), so a group that
	 * triggers nothing is byte-identical to the uncoordinated emit.
	 */
	public static function fitLineLayout(cols: Int, body: Doc, nestGluedBody: Bool, siblingWidth: Int = -1, lineWidth: Int = 0): Doc {
		final own: Doc = if (WrapList.flatLength(body) == -1) {
			final glued: Doc = Doc.Concat([Doc.OptSpace(' '), body]);
			nestGluedBody ? Doc.Nest(cols, glued) : glued;
		}
		else
			Doc.BodyGroup(Doc.Nest(cols, Doc.Concat([Doc.Line(' '), body])));
		return siblingWidth < 0
			? own
			: Doc.IfIndentWidthExceeds(siblingWidth, lineWidth, Doc.Nest(cols, Doc.Concat([Doc.Line('\n'), body])), own);
	}

}

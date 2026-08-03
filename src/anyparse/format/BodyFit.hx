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

	public static function fitLineLayout(cols: Int, body: Doc, nestGluedBody: Bool): Doc {
		if (WrapList.flatLength(body) == -1) {
			final glued: Doc = Doc.Concat([Doc.OptSpace(' '), body]);
			return nestGluedBody ? Doc.Nest(cols, glued) : glued;
		}
		return Doc.BodyGroup(Doc.Nest(cols, Doc.Concat([Doc.Line(' '), body])));
	}

}

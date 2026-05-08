package anyparse.grammar.haxe;

/**
 * One `#elseif <cond> <expr>` clause inside a `HxConditionalExpr`'s
 * `elseifs` Star. Mirror of `HxElseifDecl` / `HxElseifStmt` at
 * expression scope, with body shape diverging the same way
 * `HxConditionalExpr.expr` diverges from its decl/stmt siblings:
 * single `HxExpr` Ref, not `Array<HxExpr>` Star.
 *
 * Rationale (matches `HxConditionalExpr.hx`'s own divergence): at
 * expression scope `#elseif` wraps exactly one expression per branch
 * (canonical: `var x = #if a 1 #elseif b 2 #else 3 #end;`). Star
 * doesn't transpose because expressions don't separate with `;`
 * outside `BlockExpr`'s `{…}`; multi-statement clause bodies wrap
 * via `BlockExpr` (which is itself an `HxExpr`).
 *
 * No `@:fmt(padTrailing)` on `expr` — the trailing-space boundary
 * is owned by the parent struct's `elseifs` Star
 * (`@:fmt(padTrailing)`), which fires after the LAST clause when
 * the Star is non-empty. Putting padTrailing on each clause's
 * `expr` would compose with the Star's per-iteration `' '`
 * inter-element separator (Star helper at `WriterLowering.hx`
 * line ~5510 / ~5549) and produce `clause1_expr  #elseif clause2`
 * (double space) at every internal clause boundary. Owning the
 * trailing pad at the parent-Star level emits `' '` once, after
 * the last clause, where it's needed.
 *
 * The `#elseif` keyword sits on the first field's metadata so the
 * parent's `@:tryparse Star` loop dispatches + terminates uniformly
 * across the cond-comp cluster (HxCatchClause precedent).
 *
 * Position constraint at the call site (`HxConditionalExpr`): the
 * `elseifs` Star MUST appear before the `elseExpr` field so the
 * clause Star fully terminates before the optional `#else`
 * dispatch fires.
 *
 * `@:fmt(nestBodyOnSourceNewline)` on `expr` (slice
 * ω-cond-comp-expr-body-nest) wraps the body's leading separator in
 * `Nest(_cols, [hardline, body])` when the source had a newline at
 * the cond → expr boundary (`exprBeforeNewline=true`), placing the
 * body one indent step deeper than the `#elseif` line per the
 * expression-scope fork convention (issue_429). Inline shape
 * (`#elseif b 2`) keeps the default `' ' + body` because the
 * captured slot is false. Mirrors the `nestBodyOnSourceNewline` arm
 * of `HxConditionalExpr.expr`; `padTrailing` /
 * `captureSourceNewlineAfter` siblings on that field are intentionally
 * absent here — the parent Star (`HxConditionalExpr.elseifs`) owns
 * the trailing-pad boundary, see paragraph above.
 */
@:peg
typedef HxElseifExpr = {
	@:kw('#elseif') var cond:HxPpCondLit;
	@:fmt(nestBodyOnSourceNewline) var expr:HxExpr;
};

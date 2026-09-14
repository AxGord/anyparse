package anyparse.grammar.haxe;

/**
 * One `#elseif <cond> <expr>` clause inside a `HxConditionalExpr`'s `elseifs` Star. Mirror of
 * `HxElseifDecl` / `HxElseifStmt` at expression scope, with the body shape diverging the same
 * way `HxConditionalExpr.expr` diverges from its decl/stmt siblings: a single `HxExpr` Ref,
 * not an `Array<HxExpr>` Star — at expression scope `#elseif` wraps exactly one expression per
 * branch (`var x = #if a 1 #elseif b 2 #else 3 #end;`), expressions do not separate with `;`
 * outside `BlockExpr`'s `{…}`, and a multi-statement clause body wraps via `BlockExpr`.
 *
 * No `@:fmt(padTrailing)` on `expr` — the trailing-space boundary is owned by the parent
 * struct's `elseifs` Star (`@:fmt(padTrailing)`), which fires once after the LAST clause.
 * `padTrailing` on each clause's `expr` would compose with the Star's per-iteration `' '`
 * inter-element separator and emit a double space at every internal clause boundary.
 *
 * The `#elseif` keyword sits on the first field's metadata so the parent's `@:tryparse Star`
 * loop dispatches and terminates uniformly across the cond-comp cluster (`HxCatchClause`
 * precedent). At the call site the `elseifs` Star MUST appear before the `elseExpr` field so
 * the clause Star fully terminates before the optional `#else` dispatch fires.
 *
 * `@:fmt(nestBodyOnSourceNewline)` on `expr` (ω-cond-comp-expr-body-nest) wraps the body's
 * leading separator in `Nest(_cols, [hardline, body])` when the source had a newline at the
 * cond → expr boundary (`exprBeforeNewline=true`), placing the body one indent step deeper
 * than the `#elseif` line per the expression-scope fork convention; the inline shape keeps
 * the default `' ' + body`. Mirrors the same arm on `HxConditionalExpr.expr`; that field's
 * `padTrailing` / `captureSourceNewlineAfter` siblings are intentionally absent here because
 * the parent Star owns the trailing-pad boundary.
 */
@:peg
typedef HxElseifExpr = {
	@:kw('#elseif') var cond: HxPpCondLit;
	@:fmt(nestBodyOnSourceNewline) var expr: HxExpr;
};

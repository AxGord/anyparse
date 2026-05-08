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
 * No `@:fmt(padLeading, padTrailing)` — that meta is Star-specific.
 * Single-Ref body slots default to one inter-token space via the
 * writer's standard lead/trail emission.
 *
 * The `#elseif` keyword sits on the first field's metadata so the
 * parent's `@:tryparse Star` loop dispatches + terminates uniformly
 * across the cond-comp cluster (HxCatchClause precedent).
 *
 * Position constraint at the call site (`HxConditionalExpr`): the
 * `elseifs` Star MUST appear before the `elseExpr` field so the
 * clause Star fully terminates before the optional `#else`
 * dispatch fires.
 */
@:peg
typedef HxElseifExpr = {
	@:kw('#elseif') var cond:HxPpCondLit;
	var expr:HxExpr;
};

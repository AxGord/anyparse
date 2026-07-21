package anyparse.grammar.haxe;

/**
 * One `#elseif <cond> <type>;` clause inside a `HxConditionalType`
 * chain. Type-scope twin of `HxElseifParam` / `HxElseifMeta` /
 * `HxElseifHeritage`: the `#elseif` keyword commits the clause on
 * `cond`'s metadata (`HxCatchClause` precedent), so the parent's
 * `@:tryparse` Star loop tries the kw at each iteration and naturally
 * terminates when the next token isn't `#elseif`.
 *
 * `type` is a single `HxType` — not a Star — for the same reason the
 * parent `HxConditionalType.type` is: type-position `#if` /
 * `#elseif` / `#else` in real Haxe wraps exactly one type per branch
 * (`typedef X = #if a A; #elseif b B; #else C; #end`). Same Ref-vs-
 * Star divergence rationale as the expr/heritage/param scopes, just
 * with the single-Ref shape instead of an Array.
 *
 * `@:trailOpt(';')` mirrors the parent's per-branch semicolon: the
 * corpus form terminates each branch with `;` before the next
 * `#elseif` / `#else` / `#end`. Consume-not-store — no `trailPresent`
 * synth, so the writer re-emits via the generic separator rather than
 * source-faithfully (same deferred-byte-reemit caveat as the parent).
 *
 * Position constraint at the call site (`HxConditionalType`): the
 * `elseifs` Star MUST appear before the `elseClause` field so the
 * `#elseif` clauses fully terminate before the optional `#else`
 * dispatch fires (same ordering rule as every other conditional-
 * compilation scope's elseifs/elseBody pair).
 */
@:peg
typedef HxElseifType = {
	@:kw('#elseif') var cond: HxPpCondLit;
	@:trailOpt(';') var type: HxType;
};

package anyparse.grammar.haxe;

/**
 * One `#elseif <cond> <fields>` clause inside a `HxConditionalAnonField`
 * chain. Anon-structure-scope twin of `HxElseifHeritage` /
 * `HxElseifAbstractClause`: the `#elseif` keyword commits the clause on
 * `cond`'s metadata (`HxCatchClause` precedent), so the parent's
 * `@:tryparse` Star loop tries the kw at each iteration and terminates
 * naturally when the next token is not `#elseif`.
 *
 * Body elements are `HxAnonMember`, not `HxAnonField`, so a guarded
 * field keeps its own metadata / visibility prefix
 * (`#elseif html5 @:optional var element:js.html.Element; #end`).
 *
 * Position constraint at the call site (`HxConditionalAnonField`): the
 * `elseifs` Star MUST appear before the `elseBody` field so the
 * `#elseif` chain fully terminates before the optional `#else` dispatch
 * fires - the same ordering rule as every other conditional-compilation
 * scope's elseifs/elseBody pair.
 */
@:peg
typedef HxElseifAnonField = {
	@:kw('#elseif') var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing) var body: Array<HxAnonMember>;
};

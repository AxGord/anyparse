package anyparse.grammar.haxe;

/**
 * Grammar type for an intersection-type clause on a Haxe typedef
 * right-hand side: the `& Type` tail of `typedef X = A & B & {…}`.
 *
 * Intersection (`&`) is scoped to the typedef RHS rather than added as
 * a general `HxType` Pratt operator on purpose. In real Haxe grammar
 * `&` joins types only in typedef-RHS (structural extension) and
 * type-parameter-constraint position — it is NOT a general type
 * operator. Putting it on `HxType` makes the `is`-operator right
 * operand parser (`expr is Type`) greedily eat the first `&` of a
 * following expression-level `&&` (logical-and), because the `HxType`
 * Pratt op set has no `&&` to win the longest-match dispatch. Scoping
 * the clause to the typedef tail keeps `HxType` free of `&`, so that
 * collision cannot arise.
 *
 * A single-field struct (not an enum like the `@:kw` siblings
 * `HxHeritageClause` / `HxAbstractClause`): the lead is the literal `&`,
 * not a contextual keyword, so `@:lead('&')` on a Ref field is used
 * instead of an `@:kw` enum branch. `@:kw('&')` is rejected: Case 3
 * emits `expectKw`, whose word-boundary check would reject `A&B` (the
 * `&` is followed by an identifier).
 *
 * Around-spacing (`A & B`) is split exactly like the `extends`/`from`
 * heritage clauses: the post-`&` space comes from
 * `@:fmt(typedefIntersection)` on the `type` field (routes the
 * `@:lead('&')` through `WriterLowering.whitespacePolicyLead`; option
 * defaults to `After` → `& B`), while the pre-`&` space is structural,
 * supplied by the consuming Star's `@:fmt(padLeading)` (first clause)
 * and the bare-Star inter-element separator (subsequent clauses). A
 * struct (not enum) is required so the field hits the
 * non-optional-lead `whitespacePolicyLead` path; sibling mechanism of
 * `HxTypedefDecl.type`'s `@:fmt(typedefAssign)` `=` spacing.
 *
 * Consumed as a bare
 * `@:trivia @:tryparse var intersections:Array<HxIntersectionClause>`
 * Star on `HxTypedefDecl` (same shape as `HxClassDecl.heritage` and
 * `HxAbstractDecl.clauses`): the loop attempts the clause on each
 * iteration and terminates naturally when the next token is not `&`
 * (the `;` of the `TypedefDecl` trail, or end of input), so the common
 * no-intersection typedef adds no output.
 */
@:peg
typedef HxIntersectionClause = {
	@:fmt(typedefIntersection) @:lead('&') var type:HxType;
}

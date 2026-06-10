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
 * `@:fmt(typedefIntersectionBreak)` (ω-typedef-intersection-operand-break)
 * makes the `&`→operand whitespace a runtime decision: when the consuming
 * Star sets `opt._intersectionOperandBreak == true` (this clause follows a
 * multi-line brace-closed operand — `A & {\n…\n} & B`), the lead emits
 * `&` glued to the preceding `}` line followed by a hardline + one-tab nest
 * before the operand (`} &\n\tB`), mirroring fork `MarkLineEnds`'s
 * `lineEndAfter` on the `&` after a `BrClose`. When the flag is false (every
 * single-line intersection: `A & B`, `A & {x:Int} & B`) it falls through to
 * the `typedefIntersection` After space, byte-identical to the pre-slice
 * layout. The flag wins over `typedefIntersection` when both are present.
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
	@:fmt(typedefIntersection, typedefIntersectionBreak) @:lead('&') var type: HxType;
}

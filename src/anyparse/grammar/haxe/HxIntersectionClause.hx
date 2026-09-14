package anyparse.grammar.haxe;

/**
 * Grammar type for an intersection-type clause on a Haxe typedef right-hand side: the
 * `& Type` tail of `typedef X = A & B & {…}`.
 *
 * Intersection (`&`) is scoped to the typedef RHS rather than added as a general `HxType`
 * Pratt operator on purpose: in Haxe `&` joins types only in typedef-RHS and
 * type-parameter-constraint position. Putting it on `HxType` makes the `is`-operator right
 * operand parser (`expr is Type`) greedily eat the first `&` of a following expression-level
 * `&&`, because the `HxType` Pratt op set has no `&&` to win the longest-match dispatch.
 *
 * A single-field struct (not an enum like the `@:kw` siblings `HxHeritageClause` /
 * `HxAbstractClause`): the lead is the literal `&`, not a contextual keyword, so `@:lead('&')`
 * on a Ref field is used instead of an `@:kw` enum branch — `@:kw('&')` emits `expectKw`,
 * whose word-boundary check would reject `A&B`.
 *
 * Around-spacing (`A & B`) is split like the `extends`/`from` heritage clauses: the post-`&`
 * space comes from `@:fmt(typedefIntersection)` on the `type` field (routes the `@:lead('&')`
 * through `WriterPolicyLowering.whitespacePolicyLead`; the option defaults to `After`), while
 * the pre-`&` space is structural, supplied by the consuming Star's `@:fmt(padLeading)` (first
 * clause) and the bare-Star inter-element separator (subsequent clauses). A struct is required
 * so the field hits the non-optional-lead `whitespacePolicyLead` path; sibling mechanism of
 * `HxTypedefDecl.type`'s `@:fmt(typedefAssign)` `=` spacing.
 *
 * `@:fmt(typedefIntersectionBreak)` (ω-typedef-intersection-operand-break) makes the
 * `&`→operand whitespace a runtime decision: when the consuming Star sets
 * `opt._intersectionOperandBreak == true` (this clause follows a multi-line brace-closed
 * operand — `A & {\n…\n} & B`), the lead emits `&` glued to the preceding `}` line followed by
 * a hardline + one-tab nest before the operand (`} &\n\tB`), mirroring the fork's
 * `lineEndAfter` on the `&` after a `BrClose`; when the flag is false (every single-line
 * intersection) it falls through to the `typedefIntersection` After space. The flag wins over
 * `typedefIntersection` when both are present.
 *
 * Consumed as a bare `@:trivia @:tryparse var intersections:Array<HxIntersectionClause>` Star
 * on `HxTypedefDecl` (same shape as `HxClassDecl.heritage` and `HxAbstractDecl.clauses`): the
 * loop terminates naturally when the next token is not `&`, so the common no-intersection
 * typedef adds no output.
 */
@:peg
typedef HxIntersectionClause = {
	@:fmt(typedefIntersection, typedefIntersectionBreak) @:lead('&') var type: HxType;
}

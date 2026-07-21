package anyparse.grammar.haxe;

/**
 * Grammar type for `from`/`to` clauses in a Haxe abstract declaration.
 *
 * Shape: `from Type` or `to Type` — each clause is a keyword-introduced
 * type reference. Zero or more clauses may appear between the
 * `(UnderlyingType)` and the `{` body in an abstract declaration.
 *
 * Both branches are Case 3 (single-Ref wrapping with `@:kw`) in
 * `Lowering.lowerEnumBranch` — zero Lowering changes.
 *
 * `from` and `to` are contextual keywords - valid identifiers elsewhere
 * in Haxe. The `@:kw` strategy enforces word boundaries, so `fromage`
 * and `together` do not match.
 *
 * `Conditional` adds a `#if <cond> ... #end` region as a Star element,
 * so the `from` / `to` keyword may itself sit inside the guard
 * (`abstract ArrayBuffer(Bytes) from Bytes to Bytes #if doc_gen from
 * Dynamic to Dynamic #end`). It is the abstract-clause-scope sibling of
 * `HxHeritageClause.Conditional`, and is distinct from the conditional
 * in the TYPE slot of a clause (`from #if x A #else B #end`), which
 * `HxType` already covers via `HxConditionalType` - the two compose.
 * Body content lives in `HxConditionalAbstractClause`.
 *
 * Branch order is documentation, not disambiguation: `#if` shares no
 * prefix with `from` or `to`, and all three are word-boundary checked.
 */
@:peg
enum HxAbstractClause {

	@:kw('from')
	FromClause(type: HxType);

	@:kw('to')
	ToClause(type: HxType);

	@:kw('#if') @:trail('#end')
	Conditional(inner: HxConditionalAbstractClause);

}

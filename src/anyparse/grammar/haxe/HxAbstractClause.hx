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
 * `from` and `to` are contextual keywords — valid identifiers elsewhere
 * in Haxe. The `@:kw` strategy enforces word boundaries, so `fromage`
 * and `together` do not match.
 */
@:peg
enum HxAbstractClause {
	@:kw('from')
	FromClause(type:HxType);

	@:kw('to')
	ToClause(type:HxType);
}

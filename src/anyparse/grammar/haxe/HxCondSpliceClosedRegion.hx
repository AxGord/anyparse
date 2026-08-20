package anyparse.grammar.haxe;

/**
 * A SELF-TERMINATING token-splice `#if` region as a VALUE: the `#if`
 * keyword plus the raw fragment that swallows through its own `#end`
 * (`HxCondSpliceClosedRaw`, whose doc carries the `;` discriminator and
 * the swallow this shape exists to stop).
 *
 * Shared by the two ctors that own such a region — `HxExpr`'s
 * `CondSpliceReturnExpr` / `HxStatement`'s `CondSpliceReturnStmt` (the
 * value of a `return`) and `HxStatement.MetaCondStmt` (a metadata-prefixed
 * statement region). Both need the same two-token shape and neither can
 * spell it inline, because a branch carries at most one `@:kw` and these
 * shapes spend theirs on the `return` / on the metadata Ref — the
 * `HxVarSemiInitRegion.Conditional` precedent, where the branch spends its
 * lead slot on `=` and the `#if` rides the inner struct's first field.
 */
@:peg
typedef HxCondSpliceClosedRegion = {
	@:kw('#if') var raw: HxCondSpliceClosedRaw;
};

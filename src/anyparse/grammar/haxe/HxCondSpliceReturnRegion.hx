package anyparse.grammar.haxe;

/**
 * Body of a `return #if <cond> <fragment>; #end` expression-position
 * region: the enclosing `HxExpr.CondSpliceReturnExpr` ctor consumes the
 * `return`, this typedef owns the `#if` and the SELF-TERMINATING raw
 * fragment (`HxCondSpliceClosedRaw`, which swallows through its own
 * `#end`).
 *
 * A one-field typedef rather than a direct Ref on the ctor because a
 * branch carries at most one `@:kw` and this shape needs two - the
 * `HxVarSemiInitRegion.Conditional` precedent, where the branch spends
 * its lead slot on `=` and the `#if` rides the inner struct's first
 * field.
 */
@:peg
typedef HxCondSpliceReturnRegion = {
	@:kw('#if') var raw: HxCondSpliceClosedRaw;
};

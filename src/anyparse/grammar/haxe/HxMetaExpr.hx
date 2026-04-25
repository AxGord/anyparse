package anyparse.grammar.haxe;

/**
 * Expression-level metadata wrapper — `@:meta expr` or `@:meta(args) expr`.
 *
 * Haxe allows a metadata tag to annotate an arbitrary expression in
 * value position (call args, return values, RHS of assignments, etc.).
 * The fork corpus's `issue_241_metadata_with_parameter` exercises this
 * via `trace(@:privateAccess (X).object)` — the call argument is the
 * meta-wrapped expression `@:privateAccess (X).object`.
 *
 * Two-field Seq:
 *  - `meta` — `HxMetadata` regex terminal capturing `@name`,
 *    `@:name`, or `@:name(args)` verbatim. The leading `@` is the
 *    natural commit point that lets `HxExpr.MetaExpr` participate in
 *    `tryBranch` rollback without a peek guard: non-`@` input fails
 *    the regex on the first character and the next atom branch is
 *    tried.
 *  - `expr` — recursive `HxExpr`. Parses via the full expression
 *    function (atom + Pratt), matching Haxe's reference behavior
 *    where `@:m a + b` binds the metadata to the whole binop chain.
 *
 * The writer emits `<meta-text> <space> <expr>` because both fields
 * are bare Refs (no `@:lead`/`@:kw`/`@:trail`): the second-field
 * branch in `WriterLowering.lowerStruct` injects a default `_dt(' ')`
 * separator between consecutive Ref fields.
 */
@:peg
typedef HxMetaExpr = {
	var meta:HxMetadata;
	var expr:HxExpr;
}

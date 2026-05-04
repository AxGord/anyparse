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
 *
 * The `expr` field carries `@:fmt(allmanIndentForCtor('ObjectLit'))`
 * (slice ω-meta-allman-objectlit) so `@meta { … }` round-trips with
 * the haxe-formatter convention of placing `{` on its own line at
 * indent +1: the wrap suppresses the default `_dt(' ')` separator
 * and emits `Nest(_cols, [Hardline, writeExpr])` when the runtime
 * value's ctor is `ObjectLit`. The `Nest` bumps the current indent
 * by one step before the hardline lands, so the value's `{` sits at
 * `parent + _cols`; the `ObjectLit` writer's own internal nest then
 * pushes the body to `parent + 2·_cols`. Non-`ObjectLit` ctors fall
 * through to the inline ` value` layout. The placement is structural,
 * not configurable — there is no companion knob in `WriteOptions`.
 * Reusable on any future MetaExpr-style wrapper that gates a
 * brace-form value on the same Allman convention.
 */
@:peg
typedef HxMetaExpr = {
	var meta:HxMetadata;
	@:fmt(allmanIndentForCtor('ObjectLit'))
	var expr:HxExpr;
}

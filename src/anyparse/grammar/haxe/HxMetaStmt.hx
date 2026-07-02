package anyparse.grammar.haxe;

/**
 * Metadata-prefixed STATEMENT — `@:nullSafety(Off) if (c != null)
 * x = c;` (live dogfood shape). The common
 * `@:meta <expr>;` shape stays on the `ExprStmt(MetaExpr(...))` path
 * (tried FIRST — this ctor is the fallback for keyword statements the
 * expression route cannot terminate: an if/try whose branch statement
 * consumed its own `;`, leaving nothing for `ExprStmt`'s
 * `@:trailOpt`).
 *
 * `first` is a REQUIRED metadata entry — the branch fails fast on non-`@` input, which prevents the empty-meta + `stmt: HxStatement` self-recursion that a bare try-parse Star would create (parseHxStatement -> MetaStmt -> parseHxStatement ...). `rest` collects further metas; `stmt` recurses into the full statement grammar, so the wrapped statement owns its terminator exactly as it would unprefixed.
 */
@:peg
typedef HxMetaStmt = {
	var first: HxMetadata;
	@:trivia @:tryparse var rest: Array<HxMetadata>;
	var stmt: HxStatement;
}

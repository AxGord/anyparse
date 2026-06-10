package anyparse.grammar.haxe;

/**
 * Payload of `HxDecl.ImportAliasDecl` — single-symbol `import` with an
 * `as Name` alias clause (slice ω-import-as-alias).
 *
 * Shape: `Std.is as isOfType` — a dotted-ident `HxTypeName` followed by
 * the mandatory `as <ident>` suffix. The leading `import` keyword and
 * the trailing `;` live on the `HxDecl.ImportAliasDecl` ctor, mirroring
 * the kw/trail split on `ImportDecl` / `ImportWildDecl`. The PEG
 * lowering only supports single-Ref enum branches; multi-positional
 * ctors (`ImportAliasDecl(path, alias)`) hit "unsupported enum branch
 * shape", so both path and alias-name live here as struct fields.
 *
 * `@:kw('as')` on `alias` is hard, not `@:optional` — the wrapping ctor
 * is tried via `tryBranch` BEFORE the plain `ImportDecl(path:HxTypeName)`
 * branch, so a missing `as` here rolls back to the plain ctor (same
 * longer-match-first pattern as `ImportWildDecl` → `ImportDecl`). The
 * `as` keyword fires word-boundary matching so `aspath` is not eaten.
 *
 * The `path` field is read by
 * `WriterLowering.buildBetweenCtorBlankInfo`'s matched-ctor body so
 * the `blankLinesBetweenSameCtorByLevel` cascade sees this ctor's
 * payload as a path String — same role as `HxTypeName` carries for the
 * sibling `ImportDecl` / `ImportWildDecl` ctors.
 *
 * `using ... as ...` is not legal Haxe and is not added — only `import`
 * supports the alias form.
 */
@:peg
typedef HxImportAlias = {
	var path: HxTypeName;
	@:kw('as') var name: HxIdentLit;
}

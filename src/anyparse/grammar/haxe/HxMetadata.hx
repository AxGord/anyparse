package anyparse.grammar.haxe;

/**
 * Leading metadata tag on a class member, top-level decl, or inside
 * `HxMetaExpr` — `@name` (user metadata) or `@:name` (compiler
 * metadata), with an optional parenthesised argument block.
 *
 * Dispatched as an `@:peg` enum so structurally-known compiler metas
 * with function-decl arguments (currently `@:overload(function...)`)
 * round-trip through the structural HxOverloadFn writer — applying
 * format-driven knobs like `typeHintColon`, `funcParamParens`, etc.
 * to the inner function shape. All other meta forms fall through to
 * the verbatim `PlainMeta(raw:HxMetaRaw)` regex catch-all, preserving
 * byte-exact round-trip via the pre-existing `@:rawString` pipeline.
 *
 * Branch order matters: structural branches first (kw-led, with
 * tryBranch rollback on mismatch), regex catch-all last. The kw
 * matchers use `matchKw` (word-boundary), so `@:overload_foo` does
 * NOT collide with the `@:overload` branch — boundary check on the
 * char following the literal rejects identifier continuations.
 *
 * Used by `HxMemberDecl.meta`, `HxMetaExpr.meta`, and
 * `HxTopLevelDecl.meta` — same enum reachable via three Star/Ref
 * field positions; consumer files don't need switch dispatch unless
 * they want to inspect the structural payload.
 */
@:peg
enum HxMetadata {
	@:kw('@:overload') @:wrap('(', ')') OverloadMeta(args:HxOverloadArgs);
	PlainMeta(raw:HxMetaRaw);
}

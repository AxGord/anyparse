package anyparse.grammar.haxe;

/**
 * Leading metadata tag on a class member, top-level decl, or inside
 * `HxMetaExpr` — `@name` (user metadata) or `@:name` (compiler
 * metadata), with an optional parenthesised argument block.
 *
 * Dispatched as an `@:peg` enum across three branches in this order:
 *
 *  - `MetaCall(HxMetaCallArgs)` — paren-bearing structural form
 *    `@:name(args)`. The `HxMetaNameTight` regex uses positive
 *    lookahead `(?=\()` so any whitespace between name and `(`
 *    fails the regex and rolls back through `tryBranch`. Args parse
 *    through the standard `HxExpr` pipeline so format-driven knobs
 *    apply uniformly. This branch claims `@:overload(...)` shapes
 *    (typed and body-less anonymous functions parse via
 *    `HxExpr.FnExpr` → `HxFnExpr`).
 *  - `Meta(HxMetaName)` — bare `@:name` (no parens). Reached after
 *    `MetaCall` rolls back because no tight `(` follows the name.
 *  - `PlainMeta(HxMetaRaw)` — regex catch-all, preserves byte-
 *    exact round-trip via the `@:rawString` pipeline. Reached for
 *    metas whose args contain shapes the `HxExpr` parser doesn't
 *    cover (string-edge-cases, deeply nested parens beyond the 3-
 *    level regex bound, malformed input).
 *
 * Branch order matters: `tryBranch` saves position before each
 * branch and rolls back on `ParseError`, so an earlier branch
 * failing mid-parse cleanly retreats and the next branch tries from
 * the same start position. The split between `MetaCall` (with
 * parens) and `Meta` (no parens) is structural — the lookahead-
 * based dispatch mirrors hxformat's token-level `At`-vs-`Call`
 * `POpenType` classification, where the `(` of `@:meta(...)` is At-
 * classified ONLY when tight to the meta name.
 *
 * Used by `HxMemberDecl.meta`, `HxMetaExpr.meta`, and
 * `HxTopLevelDecl.meta` — same enum reachable via three Star/Ref
 * field positions; consumer files don't need switch dispatch unless
 * they want to inspect the structural payload.
 */
@:peg
enum HxMetadata {

	MetaCall(call: HxMetaCallArgs);
	Meta(name: HxMetaName);
	PlainMeta(raw: HxMetaRaw);

}

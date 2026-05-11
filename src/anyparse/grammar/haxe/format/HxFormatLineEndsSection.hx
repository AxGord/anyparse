package anyparse.grammar.haxe.format;

/**
 * `lineEnds` section of a haxe-formatter `hxformat.json` config.
 *
 * Only the keys whose runtime knob already exists on
 * `HxModuleWriteOptions` / base `WriteOptions` are modelled here.
 * Missing keys (`typedefCurly`, `metadataType`,
 * `metadataVar`, `metadataOther`, `caseColon`, `sharp`, …) are
 * silently dropped by the ByName struct parser's `UnknownPolicy.Skip`
 * — they land with the slice that introduces the matching writer knob.
 *
 * `lineEndCharacter` (slice ω-lineend-character) drives the base
 * `WriteOptions.lineEnd` String — `"LF"` / `"CRLF"` / `"CR"` map
 * to `\n` / `\r\n` / `\r`, `"Auto"` falls back to `\n` (no
 * source-detection plumbing).
 *
 * Per-construct sub-section `objectLiteralCurly` (slice
 * ω-objectlit-leftCurly) overrides `leftCurly` for object-literal
 * braces only, matching haxe-formatter's
 * `MarkLineEnds.getCurlyPolicy(ObjectDecl)` precedence: when present,
 * its `leftCurly` wins over the global one for the
 * `opt.objectLiteralLeftCurly` knob. Sibling sub-section
 * `anonFunctionCurly` (slice ω-anonfunction-left-curly) overrides
 * `leftCurly` for anon-function expression braces (`function() {…}`)
 * via `opt.anonFunctionLeftCurly` — same precedence rules. Sibling
 * `blockCurly` (slices ω-blockcurly + ω-blockcurly-broader) overrides
 * `leftCurly` for plain block bodies via `opt.blockLeftCurly` —
 * consumed by `HxFnDecl.body`, `HxStatement.BlockStmt`,
 * `HxExpr.BlockExpr`, `HxSwitchStmt.cases`, `HxSwitchStmtBare.cases`,
 * `HxUntypedFnBody.block`; mirrors haxe-formatter's
 * `MarkLineEnds.detectCurlyPolicy(Block)` precedence. Other
 * per-construct sub-sections (`anonTypeCurly`, …) land with their own
 * slices.
 *
 * `emptyCurly` (slice ω-empty-curly-break) drives `opt.emptyCurly`
 * — `"break"` switches empty bodies to a two-line layout (`{\n}`),
 * `"same"` keeps the flat default (`{}`).
 *
 * `rightCurly` (slice ω-blockright-curly) drives `opt.blockRightCurly`
 * — `"before"` / `"both"` collapse to `Same` (hardline before `}`,
 * default; the after-`}` newline is contributed by the surrounding
 * sibling sep), `"after"` / `"none"` collapse to `Inline` (no
 * hardline before `}`; the close glues to the last body token).
 * Plain block bodies opt in via `@:fmt(rightCurly('blockRightCurly'))`;
 * anon-fn bodies via `@:fmt(rightCurlyAnonFnOverride('anonFunctionRightCurly'))`;
 * anonymous types (`HxType.Anon`) via `@:fmt(rightCurly('anonTypeRightCurly'))`
 * (trivia branch only — wrap-engine branch deferred). Per-construct
 * sub-sections (`objectLiteralCurly.rightCurly`, …) ingest the same
 * sub-key but route to separate runtime knobs in later slices.
 */
@:peg typedef HxFormatLineEndsSection = {

	@:optional var leftCurly:HxFormatLeftCurlyPolicy;

	@:optional var rightCurly:HxFormatRightCurlyPolicy;

	@:optional var emptyCurly:HxFormatEmptyCurlyPolicy;

	@:optional var objectLiteralCurly:HxFormatCurlyLineEndPolicy;

	@:optional var anonFunctionCurly:HxFormatCurlyLineEndPolicy;

	@:optional var anonTypeCurly:HxFormatCurlyLineEndPolicy;

	@:optional var blockCurly:HxFormatCurlyLineEndPolicy;

	@:optional var metadataFunction:HxFormatMetadataLineEndPolicy;

	@:optional var lineEndCharacter:HxFormatLineEndCharacter;
};

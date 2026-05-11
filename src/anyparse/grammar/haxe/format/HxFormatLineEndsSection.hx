package anyparse.grammar.haxe.format;

/**
 * `lineEnds` section of a haxe-formatter `hxformat.json` config.
 *
 * Only the keys whose runtime knob already exists on
 * `HxModuleWriteOptions` / base `WriteOptions` are modelled here.
 * Missing keys (`rightCurly`, `anonTypeCurly`,
 * `typedefCurly`, `metadataType`, `metadataVar`, `metadataOther`,
 * `caseColon`, `sharp`, …) are silently dropped by the ByName
 * struct parser's `UnknownPolicy.Skip` — they land with the slice
 * that introduces the matching writer knob.
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
 * `blockCurly` (slice ω-blockcurly) overrides `leftCurly` for plain
 * block bodies via `opt.blockLeftCurly` — currently consumed only by
 * `HxFnDecl.body`; mirrors haxe-formatter's
 * `MarkLineEnds.getCurlyPolicy(Block)` precedence. Other per-construct
 * sub-sections (`anonTypeCurly`, …) land with their own slices.
 *
 * `emptyCurly` (slice ω-empty-curly-break) drives `opt.emptyCurly`
 * — `"break"` switches empty bodies to a two-line layout (`{\n}`),
 * `"same"` keeps the flat default (`{}`).
 */
@:peg typedef HxFormatLineEndsSection = {

	@:optional var leftCurly:HxFormatLeftCurlyPolicy;

	@:optional var emptyCurly:HxFormatEmptyCurlyPolicy;

	@:optional var objectLiteralCurly:HxFormatCurlyLineEndPolicy;

	@:optional var anonFunctionCurly:HxFormatCurlyLineEndPolicy;

	@:optional var blockCurly:HxFormatCurlyLineEndPolicy;

	@:optional var metadataFunction:HxFormatMetadataLineEndPolicy;

	@:optional var lineEndCharacter:HxFormatLineEndCharacter;
};

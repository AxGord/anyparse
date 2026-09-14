package anyparse.grammar.haxe.format;

/**
 * `lineEnds` section of a haxe-formatter `hxformat.json` config. Only the keys whose runtime
 * knob already exists on `HxModuleWriteOptions` / base `WriteOptions` are modelled here;
 * missing keys (`typedefCurly`, `metadataType`, `metadataVar`, `metadataOther`, `caseColon`,
 * `sharp`, …) are silently dropped by the ByName struct parser's `UnknownPolicy.Skip` — they
 * land with the slice that introduces the matching writer knob.
 *
 * `lineEndCharacter` drives the base `WriteOptions.lineEnd` — `"LF"` / `"CRLF"` / `"CR"` map
 * to `\n` / `\r\n` / `\r`, `"Auto"` falls back to `\n` (no source detection). `leftCurly`,
 * `emptyCurly` and `rightCurly` are the global values the loader cascades into every
 * per-construct knob; the per-construct sub-sections (`objectLiteralCurly`,
 * `anonFunctionCurly`, `blockCurly`, `anonTypeCurly`) override the cascade for their own
 * braces only, the fork's `getCurlyPolicy` / `detectCurlyPolicy` precedence. `rightCurly`
 * collapses `"before"` / `"both"` to `Same` (hardline before `}`; the after-`}` newline comes
 * from the surrounding sibling sep) and `"after"` / `"none"` to `Inline`; anonymous-type
 * braces honour it in the trivia branch only.
 */
@:peg typedef HxFormatLineEndsSection = {

	@:optional var leftCurly: HxFormatLeftCurlyPolicy;

	@:optional var rightCurly: HxFormatRightCurlyPolicy;

	@:optional var emptyCurly: HxFormatEmptyCurlyPolicy;

	@:optional var objectLiteralCurly: HxFormatCurlyLineEndPolicy;

	@:optional var anonFunctionCurly: HxFormatCurlyLineEndPolicy;

	@:optional var anonTypeCurly: HxFormatCurlyLineEndPolicy;

	@:optional var blockCurly: HxFormatCurlyLineEndPolicy;

	@:optional var metadataFunction: HxFormatMetadataLineEndPolicy;

	@:optional var lineEndCharacter: HxFormatLineEndCharacter;
};

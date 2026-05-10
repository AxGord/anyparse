package anyparse.grammar.haxe.format;

/**
 * `lineEnds` section of a haxe-formatter `hxformat.json` config.
 *
 * Only the keys whose runtime knob already exists on
 * `HxModuleWriteOptions` are modelled here. Missing keys
 * (`rightCurly`, `blockCurly`, `anonFunctionCurly`, `anonTypeCurly`,
 * `typedefCurly`, `metadataType`, `metadataVar`, `metadataOther`,
 * `caseColon`, `sharp`, `lineEndCharacter`, …) are silently dropped
 * by the ByName struct parser's `UnknownPolicy.Skip` — they land
 * with the slice that introduces the matching writer knob.
 *
 * Per-construct sub-section `objectLiteralCurly` (slice
 * ω-objectlit-leftCurly) overrides `leftCurly` for object-literal
 * braces only, matching haxe-formatter's
 * `MarkLineEnds.getCurlyPolicy(ObjectDecl)` precedence: when present,
 * its `leftCurly` wins over the global one for the
 * `opt.objectLiteralLeftCurly` knob. Other per-construct sub-sections
 * (`blockCurly`, `anonTypeCurly`, …) land with their own slices.
 *
 * `emptyCurly` (slice ω-empty-curly-break) drives `opt.emptyCurly`
 * — `"break"` switches empty bodies to a two-line layout (`{\n}`),
 * `"same"` keeps the flat default (`{}`).
 */
@:peg typedef HxFormatLineEndsSection = {

	@:optional var leftCurly:HxFormatLeftCurlyPolicy;

	@:optional var emptyCurly:HxFormatEmptyCurlyPolicy;

	@:optional var objectLiteralCurly:HxFormatCurlyLineEndPolicy;

	@:optional var metadataFunction:HxFormatMetadataLineEndPolicy;
};

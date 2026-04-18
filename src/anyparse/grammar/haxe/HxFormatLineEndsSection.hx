package anyparse.grammar.haxe;

/**
 * `lineEnds` section of a haxe-formatter `hxformat.json` config.
 *
 * Only the keys whose runtime knob already exists on
 * `HxModuleWriteOptions` are modelled here. Missing keys
 * (`rightCurly`, `emptyCurly`, `blockCurly`, `anonFunctionCurly`,
 * `anonTypeCurly`, `objectLiteralCurly`, `typedefCurly`, `metadata*`,
 * `caseColon`, `sharp`, `lineEndCharacter`, …) are silently dropped
 * by the ByName struct parser's `UnknownPolicy.Skip` — they land with
 * the slice that introduces the matching writer knob.
 */
@:peg typedef HxFormatLineEndsSection = {

	@:optional var leftCurly:HxFormatLeftCurlyPolicy;
};

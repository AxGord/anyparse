package anyparse.grammar.haxe;

/**
 * `whitespace` section of a haxe-formatter `hxformat.json` config.
 *
 * Only keys whose runtime knob already exists on `HxModuleWriteOptions`
 * are modelled here. Missing keys (`typeHintColonPolicy`,
 * `functionTypeHaxe3Policy`, `functionTypeHaxe4Policy`, `tryPolicy`,
 * `typeParamOpenPolicy`, `ifPolicy`, `arrowFunctionsPolicy`,
 * `forPolicy`, `ternaryPolicy`, …) are silently dropped by the ByName
 * struct parser's `UnknownPolicy.Skip` — they land with the slice that
 * introduces the matching writer knob.
 *
 * Added in slice ψ₇ (feeds `opt.objectFieldColon`).
 */
@:peg typedef HxFormatWhitespaceSection = {

	@:optional var objectFieldColonPolicy:HxFormatWhitespacePolicy;
};

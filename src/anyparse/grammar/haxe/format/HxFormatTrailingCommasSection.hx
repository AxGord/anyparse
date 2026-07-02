package anyparse.grammar.haxe.format;

/**
 * `trailingCommas` section of `hxformat.json` — five
 * enum-abstract-string knobs driving trailing commas in array
 * literals, call arguments, function parameter lists, object
 * literals, and anon struct types. The `objectLiteralDefault` and
 * `anonTypeDefault` keys are anyparse-specific (haxe-formatter
 * upstream preserves source) — obj-lit added in slice
 * ω-objectlit-trailing-comma as capability foundation for
 * metadata-prefix-aware obj-lit rules; anon types added so the
 * MANDATORY comma after `> Extension` entries survives the writer
 * (source presence round-trips knob-independently).
 */
@:peg typedef HxFormatTrailingCommasSection = {

	@:optional var arrayLiteralDefault: HxFormatTrailingCommaPolicy;

	@:optional var callArgumentDefault: HxFormatTrailingCommaPolicy;

	@:optional var functionParameterDefault: HxFormatTrailingCommaPolicy;

	@:optional var objectLiteralDefault: HxFormatTrailingCommaPolicy;

	@:optional var anonTypeDefault: HxFormatTrailingCommaPolicy;
};

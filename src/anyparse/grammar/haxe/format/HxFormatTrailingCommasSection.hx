package anyparse.grammar.haxe.format;

/**
 * `trailingCommas` section of `hxformat.json` — four
 * enum-abstract-string knobs driving trailing commas in array
 * literals, call arguments, function parameter lists, and object
 * literals. The `objectLiteralDefault` key is anyparse-specific
 * (haxe-formatter upstream preserves source) — added in slice
 * ω-objectlit-trailing-comma as capability foundation for
 * metadata-prefix-aware obj-lit rules.
 */
@:peg typedef HxFormatTrailingCommasSection = {

	@:optional var arrayLiteralDefault:HxFormatTrailingCommaPolicy;

	@:optional var callArgumentDefault:HxFormatTrailingCommaPolicy;

	@:optional var functionParameterDefault:HxFormatTrailingCommaPolicy;

	@:optional var objectLiteralDefault:HxFormatTrailingCommaPolicy;
};

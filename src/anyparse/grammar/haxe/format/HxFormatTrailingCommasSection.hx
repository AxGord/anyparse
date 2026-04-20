package anyparse.grammar.haxe.format;

/**
 * `trailingCommas` section of `hxformat.json` — three
 * enum-abstract-string knobs driving trailing commas in array
 * literals, call arguments, and function parameter lists.
 */
@:peg typedef HxFormatTrailingCommasSection = {

	@:optional var arrayLiteralDefault:HxFormatTrailingCommaPolicy;

	@:optional var callArgumentDefault:HxFormatTrailingCommaPolicy;

	@:optional var functionParameterDefault:HxFormatTrailingCommaPolicy;
};

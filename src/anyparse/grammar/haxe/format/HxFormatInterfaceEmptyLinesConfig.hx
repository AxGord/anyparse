package anyparse.grammar.haxe.format;

/**
 * Nested `emptyLines.interfaceEmptyLines` and `externClassEmptyLines` sections of a haxe-formatter `hxformat.json`
 * config: a type body with no static or visibility subdivision (the fork's `InterfaceFieldsEmptyLinesConfig`;
 * `enumAbstractEmptyLines` adds its doc-comment edge keys in `HxFormatEnumAbstractEmptyLinesConfig`). The loader routes
 * each section into its own knobs, never the class ones.
 */
@:peg typedef HxFormatInterfaceEmptyLinesConfig = {

	@:optional var betweenVars: Int;

	@:optional var betweenFunctions: Int;

	@:optional var afterVars: Int;

	@:optional var existingBetweenFields: HxFormatKeepEmptyLinesPolicy;

	@:optional var beginType: Int;

	@:optional var endType: Int;
};

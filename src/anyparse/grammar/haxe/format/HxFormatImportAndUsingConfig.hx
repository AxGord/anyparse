package anyparse.grammar.haxe.format;

/**
 * Nested `emptyLines.importAndUsing` section of a haxe-formatter
 * `hxformat.json` config.
 *
 * Only keys whose runtime knob already exists on `HxModuleWriteOptions`
 * are modelled here. Missing keys (`beforeType`, …) are silently
 * dropped by the ByName struct parser's `UnknownPolicy.Skip` — they
 * land with the slice that introduces the matching writer knob.
 *
 * `beforeUsing` added in slice ω-imports-using-blank — feeds
 * `opt.beforeUsing`. Matches haxe-formatter's
 * `emptyLines.importAndUsing.beforeUsing: @:default(1)`.
 *
 * `betweenImports` + `betweenImportsLevel` added in slice
 * ω-imports-using-between — feed `opt.betweenImports` and
 * `opt.betweenImportsLevel`. Match haxe-formatter's
 * `emptyLines.importAndUsing.betweenImports: @:default(0)` and
 * `emptyLines.importAndUsing.betweenImportsLevel: @:default(All)`.
 * The level field is read from JSON as a String and remapped to
 * `HxBetweenImportsLevel` by `HaxeFormatConfigLoader`.
 */
@:peg typedef HxFormatImportAndUsingConfig = {

	@:optional var beforeUsing:Int;

	@:optional var betweenImports:Int;

	@:optional var betweenImportsLevel:String;
};

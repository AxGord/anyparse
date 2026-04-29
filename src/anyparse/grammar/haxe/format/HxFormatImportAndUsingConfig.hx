package anyparse.grammar.haxe.format;

/**
 * Nested `emptyLines.importAndUsing` section of a haxe-formatter
 * `hxformat.json` config.
 *
 * Only keys whose runtime knob already exists on `HxModuleWriteOptions`
 * are modelled here. Missing keys (`betweenImports`, `betweenImportsLevel`,
 * `beforeType`, …) are silently dropped by the ByName struct parser's
 * `UnknownPolicy.Skip` — they land with the slice that introduces the
 * matching writer knob.
 *
 * Added in slice ω-imports-using-blank — feeds `opt.beforeUsing`.
 * Matches haxe-formatter's `emptyLines.importAndUsing.beforeUsing:
 * @:default(1)`.
 */
@:peg typedef HxFormatImportAndUsingConfig = {

	@:optional var beforeUsing:Int;
};

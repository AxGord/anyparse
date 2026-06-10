package anyparse.grammar.haxe.format;

/**
 * Nested `emptyLines.importAndUsing` section of a haxe-formatter
 * `hxformat.json` config.
 *
 * Only keys whose runtime knob already exists on `HxModuleWriteOptions`
 * are modelled here. Missing keys are silently dropped by the ByName
 * struct parser's `UnknownPolicy.Skip` — they land with the slice
 * that introduces the matching writer knob.
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
 *
 * `beforeType` added in slice ω-imports-using-before-type — feeds
 * `opt.beforeType`. Matches haxe-formatter's
 * `emptyLines.importAndUsing.beforeType: @:default(1)`.
 *
 * `keepSourceBlankAcrossConditional` added in Slice D12 — feeds
 * `opt.keepSourceBlankAcrossConditional`. Anyparse-specific knob with
 * no fork analogue: opt-in `true` preserves source blanks at
 * `(prevImport, #if … importB; #end)` boundaries where the head/tail
 * transparency rules would otherwise drop them via `betweenImports=0`.
 * Default `false` keeps fork-compatible (override-source-blank) behaviour.
 */
@:peg typedef HxFormatImportAndUsingConfig = {

	@:optional var beforeUsing: Int;

	@:optional var betweenImports: Int;

	@:optional var betweenImportsLevel: String;

	@:optional var beforeType: Int;

	@:optional var keepSourceBlankAcrossConditional: Bool;
};

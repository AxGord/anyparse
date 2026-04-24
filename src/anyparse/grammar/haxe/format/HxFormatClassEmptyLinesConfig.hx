package anyparse.grammar.haxe.format;

/**
 * Nested `emptyLines.classEmptyLines` section of a haxe-formatter
 * `hxformat.json` config.
 *
 * Only keys whose runtime knob already exists on `HxModuleWriteOptions`
 * are modelled here. Missing keys (`beginType`, `endType`, `beforeVars`,
 * `afterVars`, `beforeFunctions`, `afterFunctions`, `beforeStaticVars`,
 * `afterStaticVars`, `betweenStaticVars`, `beforeStaticFunctions`,
 * `afterStaticFunctions`, `betweenStaticFunctions`, `finalNewline`,
 * `afterImports`, `afterLastFunction`, `afterPrivate`, `afterPublic`,
 * `afterOverride`, `afterStatic`, `afterInline`, `afterMacro`,
 * `finalizeEmptyLines`, …) are silently dropped by the ByName struct
 * parser's `UnknownPolicy.Skip` — they land with the slice that
 * introduces the matching writer knob.
 *
 * Added in slice ω-C-empty-lines-between-fields (feeds
 * `opt.existingBetweenFields`).
 *
 * `betweenVars` / `betweenFunctions` / `afterVars` added in slice
 * ω-interblank — Int counts routed to the matching `opt.*` fields.
 * Matches haxe-formatter's `emptyLines.classEmptyLines.{betweenVars,
 * betweenFunctions, afterVars}` defaults (`0 / 1 / 1`); the anyparse
 * runtime defaults all to `0` in this slice and the default-flip
 * follows in `ω-interblank-defaults`.
 */
@:peg typedef HxFormatClassEmptyLinesConfig = {

	@:optional var existingBetweenFields:HxFormatKeepEmptyLinesPolicy;

	@:optional var betweenVars:Int;

	@:optional var betweenFunctions:Int;

	@:optional var afterVars:Int;
};

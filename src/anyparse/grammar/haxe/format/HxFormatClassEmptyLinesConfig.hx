package anyparse.grammar.haxe.format;

/**
 * Nested `emptyLines.classEmptyLines` section of a haxe-formatter
 * `hxformat.json` config.
 *
 * Only keys whose runtime knob already exists on `HxModuleWriteOptions`
 * are modelled here. Missing keys (`beginType`, `endType`, `beforeVars`,
 * `afterVars`, `betweenVars`, `beforeFunctions`, `afterFunctions`,
 * `betweenFunctions`, `beforeStaticVars`, `afterStaticVars`,
 * `betweenStaticVars`, `beforeStaticFunctions`, `afterStaticFunctions`,
 * `betweenStaticFunctions`, `finalNewline`, `afterImports`,
 * `afterLastFunction`, `afterPrivate`, `afterPublic`, `afterOverride`,
 * `afterStatic`, `afterInline`, `afterMacro`, `finalizeEmptyLines`, …)
 * are silently dropped by the ByName struct parser's
 * `UnknownPolicy.Skip` — they land with the slice that introduces the
 * matching writer knob.
 *
 * Added in slice ω-C-empty-lines-between-fields (feeds
 * `opt.existingBetweenFields`).
 */
@:peg typedef HxFormatClassEmptyLinesConfig = {

	@:optional var existingBetweenFields:HxFormatKeepEmptyLinesPolicy;
};

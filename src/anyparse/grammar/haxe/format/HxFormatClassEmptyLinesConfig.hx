package anyparse.grammar.haxe.format;

/**
 * Nested `emptyLines.classEmptyLines` section of a haxe-formatter
 * `hxformat.json` config.
 *
 * Only keys whose runtime knob already exists on `HxModuleWriteOptions`
 * are modelled here. Missing keys (`beforeVars`, `beforeFunctions`,
 * `afterFunctions`, `beforeStaticVars`, `betweenStaticVars`,
 * `beforeStaticFunctions`, `afterStaticFunctions`,
 * `finalNewline`, `afterImports`,
 * `afterLastFunction`, `afterPrivate`, `afterPublic`, `afterOverride`,
 * `afterStatic`, `afterInline`, `afterMacro`, `finalizeEmptyLines`, …)
 * are silently dropped by the ByName struct parser's
 * `UnknownPolicy.Skip` — they land with the slice that introduces the
 * matching writer knob.
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
 *
 * `afterStaticVars` added in slice ω-class-static-var-cascade — Int
 * count routed to `opt.afterStaticVars`. Default `1`, matching fork's
 * `emptyLines.classEmptyLines.afterStaticVars: @:default(1)`. Fires
 * only when the consumer Star also carries `@:fmt(staticVarSubdivision)`
 * (class + abstract members; interface skips).
 *
 * `betweenStaticFunctions` added in slice ω-abstract-static-fn-cascade —
 * Int count routed to `opt.betweenStaticFunctions`. Default `1`, matching
 * fork's `emptyLines.classEmptyLines.betweenStaticFunctions:
 * @:default(1)`. Fires only when the consumer Star also carries
 * `@:fmt(staticVarSubdivision)` and BOTH neighbours are static functions
 * (kind `4`); the default `1` is byte-identical to the pre-slice
 * `betweenFunctions` blank, so it only changes output when a config
 * lowers it (`abstractEmptyLines.betweenStaticFunctions: 0`).
 */
@:peg typedef HxFormatClassEmptyLinesConfig = {

	@:optional var existingBetweenFields:HxFormatKeepEmptyLinesPolicy;

	@:optional var betweenVars:Int;

	@:optional var betweenFunctions:Int;

	@:optional var afterVars:Int;

	@:optional var afterStaticVars:Int;

	@:optional var betweenStaticFunctions:Int;

	@:optional var beginType:Int;

	@:optional var endType:Int;
};

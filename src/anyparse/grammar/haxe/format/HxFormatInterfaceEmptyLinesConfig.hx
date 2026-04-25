package anyparse.grammar.haxe.format;

/**
 * Nested `emptyLines.interfaceEmptyLines` section of a haxe-formatter
 * `hxformat.json` config.
 *
 * Mirrors `HxFormatClassEmptyLinesConfig.{betweenVars, betweenFunctions,
 * afterVars}` but lives behind its own typedef so the loader can route
 * the values into the dedicated `opt.interfaceBetweenVars`,
 * `opt.interfaceBetweenFunctions`, `opt.interfaceAfterVars` knobs —
 * matching haxe-formatter's per-decl-type Section configs
 * (`InterfaceFieldsEmptyLinesConfig` defaults `0 / 0 / 0`).
 *
 * Other potential keys (`existingBetweenFields`, …) are silently
 * dropped by the ByName struct parser's `UnknownPolicy.Skip` until the
 * matching writer knob lands. Added in slice ω-iface-interblank.
 */
@:peg typedef HxFormatInterfaceEmptyLinesConfig = {

	@:optional var betweenVars:Int;

	@:optional var betweenFunctions:Int;

	@:optional var afterVars:Int;
};

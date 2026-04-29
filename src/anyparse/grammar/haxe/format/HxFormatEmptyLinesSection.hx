package anyparse.grammar.haxe.format;

/**
 * `emptyLines` section of a haxe-formatter `hxformat.json` config.
 *
 * Only keys whose runtime knob already exists on `HxModuleWriteOptions`
 * are modelled here. Missing keys (`finalNewline`, `maxAnywhereInFile`,
 * `beforePackage`, `betweenTypes`,
 * `lineCommentsBetweenTypes`, `lineCommentsBetweenFunctions`,
 * `betweenSingleLineTypes`, `beforeRightCurly`, `afterLeftCurly`,
 * `afterReturn`, `beforeBlocks`, `afterBlocks`, `enumAbstractEmptyLines`,
 * `macroClassEmptyLines`, `externClassEmptyLines`,
 * `abstractEmptyLines`, `enumEmptyLines`,
 * `typedefEmptyLines`, `conditionalsEmptyLines`, `afterFileHeaderComment`,
 * `betweenMultilineComments`, …) are silently dropped by the ByName
 * struct parser's `UnknownPolicy.Skip` — they land with the slice that
 * introduces the matching writer knob.
 *
 * `afterFieldsWithDocComments` added in slice ω-C-empty-lines-doc
 * (feeds `opt.afterFieldsWithDocComments`).
 *
 * `beforeDocCommentEmptyLines` added in slice ω-C-empty-lines-before-doc
 * (feeds `opt.beforeDocCommentEmptyLines`).
 *
 * `classEmptyLines` nested section added in slice
 * ω-C-empty-lines-between-fields (feeds `opt.existingBetweenFields`
 * through `HxFormatClassEmptyLinesConfig.existingBetweenFields`). Only
 * the `existingBetweenFields` sub-key is modelled today; the other
 * per-slot sub-keys (`beginType`, `endType`, `betweenVars`, …) land
 * with the slices that introduce their matching writer knobs.
 *
 * `interfaceEmptyLines` nested section added in slice
 * ω-iface-interblank (feeds `opt.interfaceBetweenVars`,
 * `opt.interfaceBetweenFunctions`, `opt.interfaceAfterVars` through
 * `HxFormatInterfaceEmptyLinesConfig`). Mirrors `classEmptyLines` for
 * interface members but with separate runtime knobs and 0/0/0 defaults
 * matching haxe-formatter's `InterfaceFieldsEmptyLinesConfig`.
 *
 * `afterPackage` added in slice ω-after-package (feeds
 * `opt.afterPackage`). Non-negative Int — minimum number of blank lines
 * the writer emits between a top-level `package …;` directive and the
 * next declaration. Default `1` matches haxe-formatter's
 * `emptyLines.afterPackage: @:default(1)`. `0` strips any blank line
 * after `package` regardless of source.
 */
@:peg typedef HxFormatEmptyLinesSection = {

	@:optional var afterFieldsWithDocComments:HxFormatCommentEmptyLinesPolicy;

	@:optional var beforeDocCommentEmptyLines:HxFormatCommentEmptyLinesPolicy;

	@:optional var classEmptyLines:HxFormatClassEmptyLinesConfig;

	@:optional var interfaceEmptyLines:HxFormatInterfaceEmptyLinesConfig;

	@:optional var afterPackage:Int;
};

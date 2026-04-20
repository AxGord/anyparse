package anyparse.grammar.haxe.format;

/**
 * `emptyLines` section of a haxe-formatter `hxformat.json` config.
 *
 * Only keys whose runtime knob already exists on `HxModuleWriteOptions`
 * are modelled here. Missing keys (`finalNewline`, `maxAnywhereInFile`,
 * `beforePackage`, `afterPackage`, `betweenTypes`,
 * `lineCommentsBetweenTypes`, `lineCommentsBetweenFunctions`,
 * `betweenSingleLineTypes`, `beforeRightCurly`, `afterLeftCurly`,
 * `afterReturn`, `beforeBlocks`, `afterBlocks`, `enumAbstractEmptyLines`,
 * `macroClassEmptyLines`, `externClassEmptyLines`,
 * `abstractEmptyLines`, `interfaceEmptyLines`, `enumEmptyLines`,
 * `typedefEmptyLines`, `conditionalsEmptyLines`,
 * `beforeDocCommentEmptyLines`, `afterFileHeaderComment`,
 * `betweenMultilineComments`, …) are silently dropped by the ByName
 * struct parser's `UnknownPolicy.Skip` — they land with the slice that
 * introduces the matching writer knob.
 *
 * `afterFieldsWithDocComments` added in slice ω-C-empty-lines-doc
 * (feeds `opt.afterFieldsWithDocComments`).
 *
 * `classEmptyLines` nested section added in slice
 * ω-C-empty-lines-between-fields (feeds `opt.existingBetweenFields`
 * through `HxFormatClassEmptyLinesConfig.existingBetweenFields`). Only
 * the `existingBetweenFields` sub-key is modelled today; the other
 * per-slot sub-keys (`beginType`, `endType`, `betweenVars`, …) land
 * with the slices that introduce their matching writer knobs.
 */
@:peg typedef HxFormatEmptyLinesSection = {

	@:optional var afterFieldsWithDocComments:HxFormatCommentEmptyLinesPolicy;

	@:optional var classEmptyLines:HxFormatClassEmptyLinesConfig;
};

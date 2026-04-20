package anyparse.grammar.haxe;

/**
 * `emptyLines` section of a haxe-formatter `hxformat.json` config.
 *
 * Only keys whose runtime knob already exists on `HxModuleWriteOptions`
 * are modelled here. Missing keys (`finalNewline`, `maxAnywhereInFile`,
 * `beforePackage`, `afterPackage`, `betweenTypes`,
 * `lineCommentsBetweenTypes`, `lineCommentsBetweenFunctions`,
 * `betweenSingleLineTypes`, `beforeRightCurly`, `afterLeftCurly`,
 * `afterReturn`, `beforeBlocks`, `afterBlocks`, `enumAbstractEmptyLines`,
 * `classEmptyLines`, `macroClassEmptyLines`, `externClassEmptyLines`,
 * `abstractEmptyLines`, `interfaceEmptyLines`, `enumEmptyLines`,
 * `typedefEmptyLines`, `conditionalsEmptyLines`,
 * `beforeDocCommentEmptyLines`, `afterFileHeaderComment`,
 * `betweenMultilineComments`, …) are silently dropped by the ByName
 * struct parser's `UnknownPolicy.Skip` — they land with the slice that
 * introduces the matching writer knob.
 *
 * Added in slice ω-C-empty-lines-doc (feeds
 * `opt.afterFieldsWithDocComments`).
 */
@:peg typedef HxFormatEmptyLinesSection = {

	@:optional var afterFieldsWithDocComments:HxFormatCommentEmptyLinesPolicy;
};

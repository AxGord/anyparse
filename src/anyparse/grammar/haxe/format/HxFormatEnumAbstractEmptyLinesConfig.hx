package anyparse.grammar.haxe.format;

/**
 * Nested `emptyLines.enumAbstractEmptyLines` section of a haxe-formatter `hxformat.json` config (the fork's
 * `EnumAbstractFieldsEmptyLinesConfig`): the `interfaceEmptyLines` keys, which the loader routes into the
 * `enumAbstract*` knobs, plus `beginTypeIfDocComments` / `endTypeIfDocComments`, the counts that replace
 * `beginType` / `endType` for a body holding a doc comment, and `afterFieldsWithDocComments`,
 * the policy after a doc-commented member (absent: the global key).
 */
@:peg typedef HxFormatEnumAbstractEmptyLinesConfig = {
	@:optional var betweenVars: Int;
	@:optional var betweenFunctions: Int;
	@:optional var afterVars: Int;
	@:optional var existingBetweenFields: HxFormatKeepEmptyLinesPolicy;
	@:optional var beginType: Int;
	@:optional var endType: Int;
	@:optional var beginTypeIfDocComments: Int;
	@:optional var endTypeIfDocComments: Int;
	@:optional var afterFieldsWithDocComments: HxFormatCommentEmptyLinesPolicy;
};

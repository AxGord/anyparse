package anyparse.grammar.haxe.format;

/**
 * A `<kind>EmptyLines` section of a haxe-formatter `hxformat.json` config of which hxq reads only the type-body
 * edges — `enumAbstractEmptyLines` and `macroClassEmptyLines`. Their other fork sub-keys (`betweenVars`,
 * `afterVars`, `betweenFunctions`, `existingBetweenFields`, …) have no knob of their own, so they are left out of
 * the schema and the config report names them instead of accepting them in silence.
 */
@:peg typedef HxFormatTypeBodyEmptyLinesConfig = {

	@:optional var beginType: Int;

	@:optional var endType: Int;
};

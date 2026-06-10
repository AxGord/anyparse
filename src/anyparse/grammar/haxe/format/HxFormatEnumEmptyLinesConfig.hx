package anyparse.grammar.haxe.format;

/**
 * Nested `emptyLines.enumEmptyLines` section of a haxe-formatter
 * `hxformat.json` config.
 *
 * Mirrors fork's `EnumFieldsEmptyLinesConfig`: a small subset of the
 * class-level shape, scoped to an `enum` body. Only sub-keys whose
 * runtime knob already exists on `HxModuleWriteOptions` are modelled
 * here; missing keys are silently dropped by the ByName struct parser.
 *
 * Added in slice ω-enum-empty-lines:
 *  - `existingBetweenFields` — Keep / Remove policy applied to source
 *    blank lines between adjacent enum constructors (feeds the GLOBAL
 *    `opt.existingBetweenFields` knob — same backing field as
 *    `classEmptyLines.existingBetweenFields`; last-write-wins when
 *    multiple type sections set it).
 *  - `betweenFields` — Int count, exact number of blank lines inserted
 *    between adjacent enum constructors. Routes to the dedicated
 *    `opt.betweenEnumCtors` knob (separate from `betweenVars` /
 *    `betweenFunctions` because enums have no var/fn split).
 *  - `beginType` — Int count, blank lines after `{` and before the first
 *    constructor. Feeds the GLOBAL `opt.beginType` knob (last-write-wins
 *    with class / interface / abstract `beginType`).
 *  - `endType` — Int count, blank lines after the last constructor and
 *    before `}`. Feeds the GLOBAL `opt.endType` knob.
 */
@:peg typedef HxFormatEnumEmptyLinesConfig = {

	@:optional var existingBetweenFields: HxFormatKeepEmptyLinesPolicy;

	@:optional var betweenFields: Int;

	@:optional var beginType: Int;

	@:optional var endType: Int;
};

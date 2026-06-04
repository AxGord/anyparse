package anyparse.grammar.haxe.format;

/**
 * Nested `emptyLines.typedefEmptyLines` section of a haxe-formatter
 * `hxformat.json` config.
 *
 * Mirrors fork's `TypedefFieldsEmptyLinesConfig`: a small subset of the
 * class-level shape, scoped to a `typedef Foo = { … }` anonymous-struct
 * body. Only sub-keys whose runtime knob already exists on
 * `HxModuleWriteOptions` are modelled here; missing keys are silently
 * dropped by the ByName struct parser.
 *
 * Added in slice ω-typedef-between-fields:
 *  - `beginType` — Int count, blank lines after the opening `{` and
 *    before the first field. Routes to the DEDICATED
 *    `opt.typedefBeginType` knob (separate from the class-scoped
 *    `opt.beginType`, which the typedef-RHS anon's `@:sep`-Star path
 *    does not read — keeps typedef / class scopes independent like the
 *    fork's distinct field-config types).
 *  - `betweenFields` — Int count, blank lines inserted between adjacent
 *    typedef fields. Routes to the dedicated `opt.typedefBetweenFields`
 *    knob.
 *  - `existingBetweenFields` — Keep / Remove policy applied to source
 *    blank lines between adjacent fields. Routes to the dedicated
 *    `opt.typedefExistingBetweenFields` knob. When `betweenFields > 0`
 *    the forced count wins regardless of this policy; it only governs
 *    the fall-through (no forced count) source-blank pass-through.
 *  - `endType` — Int count, blank lines after the last field and before
 *    the closing `}`. Routes to the dedicated `opt.typedefEndType` knob.
 */
@:peg typedef HxFormatTypedefEmptyLinesConfig = {

	@:optional var existingBetweenFields:HxFormatKeepEmptyLinesPolicy;

	@:optional var betweenFields:Int;

	@:optional var beginType:Int;

	@:optional var endType:Int;
};

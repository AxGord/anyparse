package anyparse.grammar.haxe.format;

/**
 * `emptyLines` section of a haxe-formatter `hxformat.json` config. Only keys whose runtime
 * knob exists on `HxModuleWriteOptions` are modelled; the rest (`finalNewline`,
 * `betweenTypes`, `lineCommentsBetweenTypes`, `afterReturn`, `beforeBlocks`,
 * `enumAbstractEmptyLines`, `macroClassEmptyLines`, `conditionalsEmptyLines`, …) are
 * silently dropped by the ByName struct parser's `UnknownPolicy.Skip` and land with their
 * writer knob. Each modelled key feeds the knob of the same name; every `Int` is an OVERRIDE
 * of the source-captured count, not a floor (`0` strips, `2` doubles), except
 * `betweenSingleLineTypes`, which is insertion-only (`0` leaves the slot source-driven).
 *
 * Nested sections share the fork's `EmptyLinesFieldsConfig` shape (`HxFormatClassEmptyLinesConfig`)
 * across `classEmptyLines` / `externClassEmptyLines` / `abstractEmptyLines`, and only the
 * sub-keys with a runtime knob are consumed: `existingBetweenFields` (class; the extern
 * variant feeds `externExistingBetweenFields`), `betweenStaticFunctions` (abstract, through
 * the static-function cascade arm on `HxAbstractDecl.members`); the other per-slot sub-keys
 * share the global runtime knobs, last-write wins for a config that mixes sections.
 * `interfaceEmptyLines` feeds the dedicated `interfaceBetweenVars` /
 * `interfaceBetweenFunctions` / `interfaceAfterVars` knobs (0/0/0 defaults, the fork's
 * `InterfaceFieldsEmptyLinesConfig`); `enumEmptyLines.betweenFields` feeds the dedicated
 * `betweenEnumCtors`; `typedefEmptyLines` feeds four DEDICATED `typedef*` knobs, kept
 * separate from the class scopes' shared ones because the typedef-RHS anon renders through
 * the `@:sep`-Star writer path, not the class-body Star path (the fork's distinct
 * `TypedefFieldsEmptyLinesConfig`), all defaulting to the no-blank baseline.
 * `importAndUsing` feeds `beforeUsing` / `betweenImports` / `betweenImportsLevel` /
 * `beforeType`.
 *
 * `maxAnywhereInFile` feeds the base `WriteOptions.maxConsecutiveBlanks`, the writer's
 * final-pass cap on consecutive blank lines; the loader never produces the runtime `-1`
 * ("unbounded") sentinel, which is reserved for non-Haxe grammars. `uniformStatementBlanks`
 * is an anyparse extension with no fork counterpart, so it defaults to `"keep"` (byte-inert)
 * and never re-baselines at JSON-load entry; `"collapse"` applies the "separators that
 * separate everything separate nothing" rule inside a statement block AND an array literal
 * (object literals, anon types and argument lists stay out) — see
 * `UniformStatementBlanksPolicy`.
 */
@:peg typedef HxFormatEmptyLinesSection = {

	@:optional var afterFieldsWithDocComments: HxFormatCommentEmptyLinesPolicy;

	@:optional var beforeDocCommentEmptyLines: HxFormatCommentEmptyLinesPolicy;

	@:optional var classEmptyLines: HxFormatClassEmptyLinesConfig;

	@:optional var externClassEmptyLines: HxFormatClassEmptyLinesConfig;

	@:optional var abstractEmptyLines: HxFormatClassEmptyLinesConfig;

	@:optional var interfaceEmptyLines: HxFormatInterfaceEmptyLinesConfig;

	@:optional var enumEmptyLines: HxFormatEnumEmptyLinesConfig;

	@:optional var typedefEmptyLines: HxFormatTypedefEmptyLinesConfig;

	@:optional var afterPackage: Int;

	@:optional var beforePackage: Int;

	@:optional var afterLeftCurly: HxFormatKeepEmptyLinesPolicy;

	@:optional var beforeRightCurly: HxFormatKeepEmptyLinesPolicy;

	@:optional var importAndUsing: HxFormatImportAndUsingConfig;

	@:optional var afterFileHeaderComment: Int;

	@:optional var betweenMultilineComments: Int;

	@:optional var betweenSingleLineTypes: Int;

	@:optional var aroundMultilineFields: Int;

	@:optional var uniformStatementBlanks: HxFormatUniformStatementBlanksPolicy;

	@:optional var maxAnywhereInFile: Int;
};

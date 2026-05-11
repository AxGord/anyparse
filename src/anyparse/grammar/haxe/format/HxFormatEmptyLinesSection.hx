package anyparse.grammar.haxe.format;

/**
 * `emptyLines` section of a haxe-formatter `hxformat.json` config.
 *
 * Only keys whose runtime knob already exists on `HxModuleWriteOptions`
 * are modelled here. Missing keys (`finalNewline`, `maxAnywhereInFile`,
 * `betweenTypes`,
 * `lineCommentsBetweenTypes`, `lineCommentsBetweenFunctions`,
 * `beforeRightCurly`, `afterLeftCurly`,
 * `afterReturn`, `beforeBlocks`, `afterBlocks`, `enumAbstractEmptyLines`,
 * `macroClassEmptyLines`,
 * `abstractEmptyLines`,
 * `typedefEmptyLines`, `conditionalsEmptyLines`, …) are silently dropped
 * by the ByName struct parser's `UnknownPolicy.Skip` — they land with
 * the slice that introduces the matching writer knob.
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
 * `externClassEmptyLines` nested section added in slice
 * ω-extern-existing-between-split-leading. Reuses
 * `HxFormatClassEmptyLinesConfig` (fork shares the
 * `EmptyLinesFieldsConfig` shape across regular / extern / macro class
 * scopes). Only the `existingBetweenFields` sub-key is consumed today
 * (feeds `opt.externExistingBetweenFields`); the other per-slot
 * sub-keys land alongside their extern-scoped runtime knobs as future
 * fixtures need them.
 *
 * `interfaceEmptyLines` nested section added in slice
 * ω-iface-interblank (feeds `opt.interfaceBetweenVars`,
 * `opt.interfaceBetweenFunctions`, `opt.interfaceAfterVars` through
 * `HxFormatInterfaceEmptyLinesConfig`). Mirrors `classEmptyLines` for
 * interface members but with separate runtime knobs and 0/0/0 defaults
 * matching haxe-formatter's `InterfaceFieldsEmptyLinesConfig`.
 *
 * `enumEmptyLines` nested section added in slice ω-enum-empty-lines.
 * Drives blank-line behaviour inside `enum` bodies — its `betweenFields`
 * sub-key feeds the dedicated `opt.betweenEnumCtors` knob; the rest
 * (`existingBetweenFields`, `beginType`, `endType`) share the global
 * runtime knobs with class / interface / abstract sections (last-write
 * wins for fixtures that mix sections).
 *
 * `afterPackage` added in slice ω-after-package (feeds
 * `opt.afterPackage`). Non-negative Int — exact number of blank lines
 * the writer emits between a top-level `package …;` directive and the
 * next declaration. Override semantics, not floor: the source-captured
 * blank-line count is always replaced with this value, so `0` strips
 * any blank line after `package` even when the source had one and `2`
 * emits two blank lines even when the source had none. Default `1`
 * matches haxe-formatter's `emptyLines.afterPackage: @:default(1)`.
 *
 * `beforePackage` added in slice ω-before-package (feeds
 * `opt.beforePackage`). Non-negative Int — exact number of blank lines
 * the writer emits at file head BEFORE a leading `package …;` decl.
 * Override semantics, head-of-Star only: applied once at the start of
 * the module. Default `0` matches haxe-formatter's
 * `emptyLines.beforePackage: @:default(0)`.
 *
 * `importAndUsing` nested section added in slice ω-imports-using-blank
 * (feeds `opt.beforeUsing` through `HxFormatImportAndUsingConfig`).
 * Mirrors haxe-formatter's `emptyLines.importAndUsing` group;
 * `beforeUsing` (ω-imports-using-blank) and
 * `betweenImports` + `betweenImportsLevel` (ω-imports-using-between)
 * are modelled today, the remaining sub-key (`beforeType`) lands with
 * the slice that introduces its matching writer knob.
 *
 * `afterFileHeaderComment` / `betweenMultilineComments` added in slice
 * ω-fileheader-multiline-comments. Non-negative Int knobs that drive
 * the writer's per-leadingComments-array blank-line policy. See
 * `HxModuleWriteOptions.afterFileHeaderComment` /
 * `HxModuleWriteOptions.betweenMultilineComments` for full semantics.
 *
 * `betweenSingleLineTypes` added in slice ω-between-single-line-types
 * (feeds `opt.betweenSingleLineTypes`). Non-negative Int — number of
 * blank lines emitted between any consecutive pair of single-line type
 * decls (typedef / class / interface / abstract / enum where neither
 * matches the grammar-derived `multiline` predicate). Insertion-only:
 * `0` (default, matches haxe-formatter's
 * `emptyLines.betweenSingleLineTypes: @:default(0)`) leaves the slot
 * source-driven; `>0` forces that many blanks regardless of source.
 */
@:peg typedef HxFormatEmptyLinesSection = {

	@:optional var afterFieldsWithDocComments:HxFormatCommentEmptyLinesPolicy;

	@:optional var beforeDocCommentEmptyLines:HxFormatCommentEmptyLinesPolicy;

	@:optional var classEmptyLines:HxFormatClassEmptyLinesConfig;

	@:optional var externClassEmptyLines:HxFormatClassEmptyLinesConfig;

	@:optional var interfaceEmptyLines:HxFormatInterfaceEmptyLinesConfig;

	@:optional var enumEmptyLines:HxFormatEnumEmptyLinesConfig;

	@:optional var afterPackage:Int;

	@:optional var beforePackage:Int;

	@:optional var afterLeftCurly:HxFormatKeepEmptyLinesPolicy;

	@:optional var beforeRightCurly:HxFormatKeepEmptyLinesPolicy;

	@:optional var importAndUsing:HxFormatImportAndUsingConfig;

	@:optional var afterFileHeaderComment:Int;

	@:optional var betweenMultilineComments:Int;

	@:optional var betweenSingleLineTypes:Int;
};

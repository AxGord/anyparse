package anyparse.format.wrap;

/**
 * Per-construct wrap-rules cascade. The writer measures a delimited
 * list's element count, max item flat width, total flat width and an
 * `exceedsMaxLineLength` flag, walks `rules` in order, and selects the
 * first rule whose conditions all hold. When no rule matches,
 * `defaultMode` applies.
 *
 * Format-neutral — lives in `anyparse.format.wrap` so any delimited-
 * list site in any text grammar (object literal, array literal, anon
 * type body, call args, function params, …) can opt into the same
 * engine through a `@:fmt(wrapRules('<optionFieldName>'))` annotation
 * on its `Star` field. The rule set lives in `WriteOptions` (or a
 * grammar-specific extension struct) so end-user `hxformat.json`-style
 * config can override it without recompiling.
 *
 * Mirrors haxe-formatter's `WrapRules` typedef (AxGord fork's
 * `src/formatter/config/WrapConfig.hx`); per-construct defaults are
 * ported from `resources/default-hxformat.json` for byte-level parity
 * during the migration. The shape skips haxe-formatter's
 * `additionalIndent` rule field — interacts with the upstream
 * tokenizer-level wrapping logic and has no analogue in the Doc IR.
 *
 * `defaultLocation` (optional) governs operator placement when the
 * cascade falls through to `defaultMode` OR a matching rule has no
 * explicit `location`. Defaults to `AfterLast` at the runtime sites
 * that consume it (`BinaryChainEmit`), mirroring haxe-formatter's
 * `WrapRules.defaultLocation: AfterLast` typedef default. Currently
 * consumed only by chain emission — delimited-list shapes
 * (`WrapList.emit`) ignore it.
 */
typedef WrapRules = {
	var rules:Array<WrapRule>;
	var defaultMode:WrapMode;
	@:optional var defaultLocation:WrappingLocation;
};

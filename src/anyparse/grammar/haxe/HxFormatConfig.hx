package anyparse.grammar.haxe;

/**
 * Declarative schema for the subset of `hxformat.json` keys the
 * Haxe writer understands. Parsed by the macro-generated
 * `HxFormatConfigParser` (ByName struct lowering, τ₄) and mapped
 * into `HxModuleWriteOptions` by `HaxeFormatConfigLoader`.
 *
 * Every field is `@:optional` — an empty `{}` config is valid and
 * produces a `HxFormatConfig` with all-null sections, which the
 * loader then materialises as `HaxeFormat.instance.defaultWriteOptions`.
 *
 * Top-level sections modelled here track the `HxModuleWriteOptions`
 * surface exposed to callers. Everything else (`whitespace`,
 * `emptyLines`, `baseTypeHints`, …) lands with the slice that
 * introduces the matching `HxModuleWriteOptions` knob — the loader's
 * forward-compat contract silently drops unknown keys, and the macro
 * parser's `UnknownPolicy.Skip` inherited from `JsonFormat` enforces
 * that at compile time.
 *
 * `lineEnds` section added in slice ψ₆ (feeds `opt.leftCurly`).
 *
 * `whitespace` section added in slice ψ₇ (feeds `opt.objectFieldColon`).
 *
 * `emptyLines` section added in slice ω-C-empty-lines-doc (feeds
 * `opt.afterFieldsWithDocComments`).
 */
@:peg @:schema(anyparse.format.text.JsonFormat) @:ws
typedef HxFormatConfig = {

	@:optional var indentation:HxFormatIndentationSection;

	@:optional var wrapping:HxFormatWrappingSection;

	@:optional var sameLine:HxFormatSameLineSection;

	@:optional var trailingCommas:HxFormatTrailingCommasSection;

	@:optional var lineEnds:HxFormatLineEndsSection;

	@:optional var whitespace:HxFormatWhitespaceSection;

	@:optional var emptyLines:HxFormatEmptyLinesSection;
};

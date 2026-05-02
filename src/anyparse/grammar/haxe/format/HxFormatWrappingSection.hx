package anyparse.grammar.haxe.format;

/**
 * `wrapping` section of `hxformat.json`.
 *
 *  - `maxLineLength`: int → `lineWidth`.
 *  - `arrayWrap`: `WrapRules` cascade → `arrayLiteralWrap` (slice
 *    ω-arraylit-wraprules). Other per-construct cascades
 *    (`objectLiteral`, `callParameter`, …) land with their own slices
 *    when each gains JSON-side wiring; the matching `WriteOptions`
 *    fields exist already but are still populated only from the
 *    `HaxeFormat.default*Wrap()` defaults.
 */
@:peg typedef HxFormatWrappingSection = {

	@:optional var maxLineLength:Int;

	@:optional var arrayWrap:HxFormatWrapRules;
};

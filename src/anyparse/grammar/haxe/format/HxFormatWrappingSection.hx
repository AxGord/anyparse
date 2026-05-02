package anyparse.grammar.haxe.format;

/**
 * `wrapping` section of `hxformat.json`.
 *
 *  - `maxLineLength`: int → `lineWidth`.
 *  - `arrayWrap`: `WrapRules` cascade → `arrayLiteralWrap` (slice
 *    ω-arraylit-wraprules).
 *  - `anonType`: `WrapRules` cascade → `anonTypeWrap` (slice
 *    ω-anontype-wraprules).
 *  - `methodChain`: `WrapRules` cascade → `methodChainWrap` (slice
 *    ω-methodchain-wraprules-capability — knob + loader only, writer
 *    wiring lands in a follow-up slice; see
 *    `HxModuleWriteOptions.methodChainWrap` doc paragraph). The
 *    remaining per-construct cascades (`objectLiteral`, `callParameter`,
 *    …) land with their own slices when each gains JSON-side wiring;
 *    the matching `WriteOptions` fields exist already but are still
 *    populated only from the `HaxeFormat.default*Wrap()` defaults.
 */
@:peg typedef HxFormatWrappingSection = {

	@:optional var maxLineLength:Int;

	@:optional var arrayWrap:HxFormatWrapRules;

	@:optional var anonType:HxFormatWrapRules;

	@:optional var methodChain:HxFormatWrapRules;
};

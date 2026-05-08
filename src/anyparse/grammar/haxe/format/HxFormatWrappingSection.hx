package anyparse.grammar.haxe.format;

/**
 * `wrapping` section of `hxformat.json`.
 *
 *  - `maxLineLength`: int → `lineWidth`.
 *  - `arrayWrap`: `WrapRules` cascade → `arrayLiteralWrap` (slice
 *    ω-arraylit-wraprules).
 *  - `anonType`: `WrapRules` cascade → `anonTypeWrap` (slice
 *    ω-anontype-wraprules).
 *  - `methodChain`: `WrapRules` cascade → `methodChainWrap` (slices
 *    ω-methodchain-wraprules-capability + ω-methodchain-emit — knob,
 *    loader, and writer-time chain extractor all wired).
 *  - `opBoolChain`: `WrapRules` cascade → `opBoolChainWrap` (slice
 *    ω-binop-wraprules — drives `||` / `&&` chain break shape;
 *    knob + loader + macro-time dispatch all wired).
 *  - `opAddSubChain`: `WrapRules` cascade → `opAddSubChainWrap` (same
 *    slice — drives `+` / `-` chain break shape).
 *  - `callParameter`: `WrapRules` cascade → `callParameterWrap` (slice
 *    ω-wrapping-callParameter-ingest — knob, loader, and writer
 *    dispatch via `@:fmt(wrapRules('callParameterWrap'))` on
 *    `HxExpr.Call.args` and `HxNewExpr.args` are now wired).
 *  - `objectLiteral`: `WrapRules` cascade → `objectLiteralWrap` (slice
 *    ω-wrapping-objectLiteral-ingest — knob, default, and writer
 *    dispatch via `@:fmt(wrapRules('objectLiteralWrap'))` on
 *    `HxObjectLit.fields` were already wired before this slice; only
 *    the loader-side mapping was missing).
 *
 * Slice ω-peg-byname-array lifted the prior `@:peg` ByName Array<T>
 * limitation, so every cascade above now ingests `rules` from
 * `hxformat.json` verbatim (rules with the still-unmodelled
 * `lineLength >= n` predicate are silently dropped at load time so the
 * cascade falls through to the next rule).
 *
 * The remaining per-construct cascades (`conditionWrapping`,
 * `expressionWrapping`, `typeParameter`, `arrayMatrixWrap`, …) land
 * with their own slices when each gains JSON-side wiring; matching
 * `WriteOptions` fields don't exist yet and need new fields plus
 * grammar `@:fmt` wiring.
 */
@:peg typedef HxFormatWrappingSection = {

	@:optional var maxLineLength:Int;

	@:optional var arrayWrap:HxFormatWrapRules;

	@:optional var anonType:HxFormatWrapRules;

	@:optional var methodChain:HxFormatWrapRules;

	@:optional var opBoolChain:HxFormatWrapRules;

	@:optional var opAddSubChain:HxFormatWrapRules;

	@:optional var callParameter:HxFormatWrapRules;

	@:optional var objectLiteral:HxFormatWrapRules;
};

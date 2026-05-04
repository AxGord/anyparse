package anyparse.grammar.haxe.format;

/**
 * One rule of a `wrapping.<name>.rules[]` cascade in `hxformat.json`:
 *
 * ```json
 * {
 *     "type": "onePerLineAfterFirst",
 *     "location": "beforeLast",
 *     "conditions": [
 *         {"cond": "itemCount >= n", "value": 4}
 *     ]
 * }
 * ```
 *
 * `type` is the resulting `WrapMode` string (`noWrap` / `onePerLine` /
 * `onePerLineAfterFirst` / `fillLine` / `fillLineWithLeadingBreak`).
 * The loader drops the rule entirely when the string isn't recognised.
 *
 * `location` (optional) is the operator-placement axis for chain
 * shapes that break across lines (`beforeLast` / `afterLast`). When
 * unset, the parent `defaultLocation` (or the engine fallback)
 * applies. Has no effect on `noWrap` rules or on delimited-list
 * shapes — only chain emit (`BinaryChainEmit`) consumes it.
 *
 * `conditions` is the AND-list of predicates required for the rule to
 * fire. A rule whose `conditions` contains an unmodelled `cond` string
 * (e.g. `lineLength >= n`) is silently skipped at load time so the
 * cascade falls through to the next rule instead of producing
 * malformed output.
 *
 * Schema added in slice ω-peg-byname-array; `location` added in slice
 * ω-binop-location.
 */
@:peg typedef HxFormatWrapRule = {

	@:optional var type:String;

	@:optional var location:String;

	@:optional var conditions:Array<HxFormatWrapCondition>;
};

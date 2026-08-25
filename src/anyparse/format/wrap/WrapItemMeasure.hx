package anyparse.format.wrap;

/**
 * The per-list measurements a `WrapRules` cascade tests its conditions
 * against. One shape for all three emitters — `WrapList.measureItems`,
 * `BinaryChainEmit.measureChain` and `MethodChainEmit.measureSegments` —
 * so a condition added to `WrapConditionType` has one place per emitter
 * to be fed from.
 *
 * `minLen` / `equalLens` mirror the fork's `minItemLength` and
 * `hasEqualItemLenghts` locals in `MarkWrappingBase.determineWrapType2`,
 * including its empty-list sentinel: with no items `minLen` stays
 * `WrapList.MAX_ITEM_LEN`, so `anyItemLength <= n` answers false rather
 * than firing on a zero (`allItemLengths >= n` reads that sentinel as
 * matching — see `MAX_ITEM_LEN`'s own note).
 *
 * The three emitters do NOT measure the same way, and cannot: a delimited
 * list charges each non-last item for its trailing separator, a binary
 * chain charges each non-first operand for its LEADING operator, and a
 * method chain has no separator at all. Each one's own doc says how it
 * spells `equalLens` under its arrangement.
 */
typedef WrapItemMeasure = {
	var total: Int;
	var maxLen: Int;
	var minLen: Int;
	var equalLens: Bool;
	var anyHardline: Bool;
};

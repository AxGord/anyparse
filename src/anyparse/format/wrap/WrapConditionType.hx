package anyparse.format.wrap;

/**
 * Predicate kind tested by one `WrapCondition` against a measured delimited list:
 * the `WrapRules` cascade evaluates each rule's conditions in AND order and takes
 * the first rule whose conditions all hold.
 *
 * A condition whose name carries a threshold reads `WrapCondition.value` as that
 * threshold, and the polarity-only ones read it as `1` for "the signal holds" and
 * `0` for "it does not". Item width is per-construct — a delimited list charges
 * every item but the last for its trailing separator while a chain measures its
 * operands bare — so `EqualItemLengths` is a question about the measuring
 * emitter's own charge and each emitter spells it.
 *
 * `ExceedsMaxLineLength` and `LineLengthLargerThan` are answered at RENDER time,
 * not at cascade time: the engine walks the cascade across (exceeds,
 * lineLength-firing) states and, where the outcomes disagree, wraps the emit in
 * `Doc.Group(IfBreak(…))` / one `Doc.IfWidthExceeds(n, …)` per distinct threshold,
 * so the renderer's own column probe picks the mode.
 *
 * Format-neutral — the same conditions apply to any delimited list in any grammar.
 * Per-condition semantics, the JSON spellings they map from, and the fork-shipped
 * spellings hxq refuses are documented once, in `docs/haxe-format-config.md`
 * § `rules[].conditions[].cond`.
 */
enum abstract WrapConditionType(Int) from Int to Int {

	final ItemCountLargerThan = 0;

	final ItemCountLessThan = 1;

	final AnyItemLengthLargerThan = 2;

	final AllItemLengthsLessThan = 3;

	final TotalItemLengthLargerThan = 4;

	final TotalItemLengthLessThan = 5;

	final ExceedsMaxLineLength = 6;

	final LineLengthLargerThan = 7;

	final HasMultilineItems = 8;

	final ComplexItemCountLargerThan = 9;

	final AllItemLengthsLargerThan = 10;

	final AnyItemLengthLessThan = 11;

	final EqualItemLengths = 12;

	final HasContainerItems = 13;

	final HasMultilineLambdaItems = 14;

}

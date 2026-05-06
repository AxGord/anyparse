package anyparse.format.wrap;

/**
 * Predicate kind tested by a single `WrapCondition` against a measured
 * delimited list. The cascade in `WrapRules` evaluates each rule's
 * conditions in AND order; the first rule whose conditions all hold is
 * selected.
 *
 *  - `ItemCountLargerThan` / `ItemCountLessThan` — `length >= n` /
 *    `length <= n` against the list's element count.
 *  - `AnyItemLengthLargerThan` — `max(itemFlatLength) >= n`. Triggers
 *    when at least one item is wider than `n` columns in flat layout.
 *  - `AllItemLengthsLessThan` — `max(itemFlatLength) <= n`. Triggers
 *    when every item fits within `n` columns.
 *  - `TotalItemLengthLargerThan` / `TotalItemLengthLessThan` — same
 *    inequality against the sum of all item flat widths.
 *  - `ExceedsMaxLineLength` — pseudo-condition asking whether the list
 *    in `NoWrap` mode would exceed `WriteOptions.lineWidth`. The
 *    condition's `value` field is unused (haxe-formatter passes `1`
 *    by convention). The writer evaluates the cascade twice — once
 *    with `exceeds=false`, once with `exceeds=true` — and emits a
 *    runtime `Doc.Group(IfBreak(brkDoc, flatDoc))` shape when the two
 *    runs disagree, so the renderer's flat/break decision picks the
 *    right mode at layout time. When both runs agree, the chosen mode
 *    is unconditional and no Group wrap is needed.
 *  - `LineLengthLargerThan` — `totalItemFlatLength >= n` against the
 *    construct's own flat width. Differs from `TotalItemLengthLargerThan`
 *    only by intent: haxe-formatter's `lineLength >= n` is conceptually
 *    "would the rendered line at this point cross threshold N", which
 *    anyparse approximates as the construct's flat width without
 *    column prefix. Mapped from JSON `'lineLength >= n'` (slice
 *    ω-linelen-static).
 *  - `HasMultilineItems` — `anyHardline == (value != 0)`. Triggers when
 *    at least one item carries a forced hardline (`Line('\n')` or
 *    `OptHardline`) anywhere in its `Doc` subtree, including inside
 *    `BodyGroup` (i.e. matches the legacy `flatLength(item) < 0`
 *    semantic). Replaces the prior `HARDLINE_LEN` inflation hack — the
 *    cascade now expresses "items have multi-line content" as an
 *    explicit predicate instead of relying on `total/maxLen` blowing
 *    past every threshold. Mapped from JSON `'hasMultilineItems'`
 *    (slice ω-flatlength-decouple-tokenwidth).
 *
 * Format-neutral — same conditions apply to any delimited list across
 * languages. Mirrors haxe-formatter's `WrapConditionType` enum
 * (AxGord fork's `src/formatter/config/WrapConfig.hx`).
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
}

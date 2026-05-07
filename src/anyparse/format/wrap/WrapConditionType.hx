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
 *  - `LineLengthLargerThan` — column-aware "would `column +
 *    flatTokenWidth(item) >= n` at the renderer's layout time". Routed
 *    through `Doc.IfWidthExceeds(n, brk, flat)` by the engine — the
 *    static cascade walk in `decideWithLineLengthState` defers the
 *    answer to a caller-supplied `lineLengthFires` predicate, and
 *    `WrapList.emit` / `BinaryChainEmit.emit` / `MethodChainEmit.emit`
 *    enumerate cascade outcomes across (exceeds, lineLength-firing)
 *    states and emit one `IfWidthExceeds` wrapper per distinct
 *    threshold so the renderer probes column position at layout time.
 *    When the threshold equals `WriteOptions.lineWidth` the cascade
 *    collapses to the existing `exceeds` semantic via the standard
 *    `IfBreak` pivot. Mapped from JSON `'lineLength >= n'` (slice
 *    ω-linelen-static introduced the cond; ω-ifwidthexceeds-infra
 *    added the column-aware Doc primitive; ω-methodchain-threshold-aware
 *    completed migration of all callers).
 *  - `HasMultilineItems` — `anyHardline == (value != 0)`. Triggers when
 *    at least one item carries a forced hardline (`Line('\n')` or
 *    `OptHardline`) anywhere in its `Doc` subtree, including inside
 *    `BodyGroup` (i.e. matches the legacy `flatLength(item) < 0`
 *    semantic). Replaces the prior `HARDLINE_LEN` inflation hack
 *    (deleted in slice ω-methodchain-threshold-aware) — the cascade now
 *    expresses "items have multi-line content" as an explicit predicate
 *    instead of relying on `total/maxLen` blowing past every threshold.
 *    Mapped from JSON `'hasMultilineItems'` (slice
 *    ω-flatlength-decouple-tokenwidth).
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

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
 *  - `AllItemLengthsLargerThan` — `min(itemFlatLength) >= n`. Triggers
 *    when EVERY item is at least `n` columns wide.
 *  - `AnyItemLengthLessThan` — `min(itemFlatLength) <= n`. Triggers
 *    when at least one item is `n` columns or narrower.
 *  - `EqualItemLengths` — `equalItemLengths == (value != 0)`. A
 *    predicate over the WHOLE item set rather than a threshold: every
 *    item must measure the same flat width. Which width that is, is the
 *    measuring emitter's business — a delimited list charges every item
 *    but the last for its trailing separator and lets the last one come
 *    out that much narrower, a chain measures its operands bare. Mirrors the fork's `hasEqualItemLenghts` loop in
 *    `MarkWrappingBase.determineWrapType2`, whose `(length + 2) ==
 *    itemLength` allowance is the same correction for a two-character
 *    separator — and is a literal 2, so an emitter whose per-item charge
 *    is any other width has to spell its own (`BinaryChainEmit` does,
 *    and says why). Mapped from JSON `'equalItemLengths'`.
 *  - `TotalItemLengthLargerThan` / `TotalItemLengthLessThan` — same
 *    inequality against the sum of all item flat widths.
 *  - `ExceedsMaxLineLength` — pseudo-condition asking whether the list
 *    in `NoWrap` mode would exceed `WriteOptions.lineWidth`. `value: 1`
 *    matches when it would, `value: 0` when it would not — the fork
 *    ships rules of BOTH polarities (`itemCount <= 3` paired with
 *    `exceedsMaxLineLength: 0` is its standard "short and it fits" noWrap
 *    arm), so the field is read, not decoration. The writer evaluates the cascade twice — once
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
 *  - `ComplexItemCountLargerThan` — `complexItemCount >= n`, where an
 *    item counts as COMPLEX when the AST layer classified it as a
 *    constructor call / function call, or as a container literal
 *    (object / array) carrying a call or `new` anywhere in its subtree.
 *    The per-element classification is a grammar-side question, so the
 *    writer supplies it through `WrapListOptions.complexItemKinds`, which
 *    the Haxe grammar sets at three Stars only — array-literal elements,
 *    call arguments, `new` arguments. Every other wrap class supplies no
 *    kinds, counts 0, and cannot fire the condition for any `value >= 1`
 *    (which is every shipped config, since an omitted `value` reads 1).
 *    Deliberately SEMANTIC rather than width-based: the
 *    same cascade also governs array PATTERNS in `case` arms and
 *    switch-subject arrays, whose elements are identifiers and
 *    wildcards, so a width proxy mangles them while this counter cannot
 *    reach them. Mapped from JSON `'complexItemCount >= n'` (slice
 *    D1 — complex-element arrays).
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
 *  - `HasContainerItems` — "at least one element is a container literal"
 *    `== (value != 0)`. Reads the SAME `complexItemKinds` array as
 *    `ComplexItemCountLargerThan`, but the other half of it: both the
 *    call-bearing container and the bare one answer true, while a call,
 *    an identifier or a literal answers false. It exists because the two
 *    questions genuinely differ — `complexItemCount` asks "does this element
 *    carry work", this asks "is this element a brace construct" — and a
 *    bare `{x: 1, y: 2}` argument answers only the second. Its motivating
 *    consumer is `callParameter`: an argument list that mixes a container
 *    with a multi-line one cannot start the multi-line argument on the
 *    call line and stay readable. Mapped from JSON `'hasContainerItems'`.
 *  - `HasMultilineLambdaItems` — "a MULTI-LINE element is a function literal"
 *    `== (value != 0)`. The same kinds array crossed with each element's own
 *    rendered Doc, because neither half answers alone: `HasMultilineItems`
 *    says something here breaks but not WHICH element does, and the two
 *    shapes it conflates want opposite layouts — an argument list whose
 *    multi-line element is a CALLBACK should not start it on the call line,
 *    while one whose multi-line element is the collection itself is exactly
 *    what the multi-arg collection glue hugs to the head. Mapped from JSON
 *    `'hasMultilineLambdaItems'`.
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

	final ComplexItemCountLargerThan = 9;

	final AllItemLengthsLargerThan = 10;

	final AnyItemLengthLessThan = 11;

	final EqualItemLengths = 12;

	final HasContainerItems = 13;

	final HasMultilineLambdaItems = 14;

}

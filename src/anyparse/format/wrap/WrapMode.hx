package anyparse.format.wrap;

/**
 * Layout strategy chosen for a delimited list (object literal, array
 * literal, anonymous-type body, call argument list, …) by the
 * `WrapRules` cascade.
 *
 *  - `NoWrap` — items stay on one line (`{a: 1, b: 2}`).
 *  - `OnePerLine` — each item on its own indented line, including the
 *    first (`{\n\titem,\n\titem\n}`).
 *  - `OnePerLineAfterFirst` — first item stays inline with the open
 *    delim; remaining items each on their own indented line.
 *  - `FillLine` — Wadler `fillSep`-style packing: items pack inline up
 *    to the line budget, the separator before the offending item
 *    breaks at the list's continuation indent.
 *  - `FillLineWithLeadingBreak` — same as `FillLine` but always emits a
 *    line break between the open delim and the first item, so the
 *    first item starts on the indented continuation line. Currently
 *    treated identically to `FillLine` at the writer; reserved for
 *    callers that want the leading-break shape verbatim once a future
 *    slice differentiates the two.
 *
 * Format-neutral — lives in `anyparse.format.wrap` so any text grammar
 * can drive its delimited-list layout through the same engine.
 *
 * Mirrors haxe-formatter's `WrappingType` enum (the AxGord fork's
 * `src/formatter/config/WrapConfig.hx`) so the JSON-config-driven
 * defaults can be ported verbatim.
 */
enum abstract WrapMode(Int) from Int to Int {

	final NoWrap = 0;

	final OnePerLine = 1;

	final OnePerLineAfterFirst = 2;

	final FillLine = 3;

	final FillLineWithLeadingBreak = 4;
}

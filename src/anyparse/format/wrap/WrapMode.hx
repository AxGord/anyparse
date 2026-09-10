package anyparse.format.wrap;

/**
 * Layout strategy chosen for a delimited list (object literal, array literal,
 * anonymous-type body, call argument list, …) by the `WrapRules` cascade.
 * Format-neutral, so any text grammar can drive its delimited-list layout
 * through the same engine.
 *
 *  - `NoWrap` — items stay on one line (`{a: 1, b: 2}`).
 *  - `OnePerLine` — each item on its own indented line, the first included.
 *  - `OnePerLineAfterFirst` — first item inline with the open delim, the rest
 *    one per indented line.
 *  - `FillLine` — Wadler `fillSep`-style packing: items pack inline up to the
 *    line budget, and the separator before the offending item breaks at the
 *    list's continuation indent.
 *  - `FillLineWithLeadingBreak` — `FillLine` plus a forced break between the
 *    open delim and the first item. Treated identically to `FillLine` at the
 *    writer until a caller needs the two distinguished.
 */
enum abstract WrapMode(Int) from Int to Int {

	final NoWrap = 0;

	final OnePerLine = 1;

	final OnePerLineAfterFirst = 2;

	final FillLine = 3;

	final FillLineWithLeadingBreak = 4;

	/**
	 * Source-newline preservation: each element's hardline-vs-glue decision reads
	 * `Trivial<T>.newlineBefore` at the writer site.
	 *
	 * Effective only at the trivia-emit branch (`TriviaSepLowering.triviaSepStarExpr`).
	 * The cascade engine's `shape` switch maps `Keep → shapeNoWrap` as a defensive
	 * fallback, because the writer pre-empts a Keep cascade before invoking
	 * `WrapList.emit` — a Keep rule that does reach the engine then gets a sensible
	 * single-line layout instead of a crash.
	 */
	final Keep = 5;

	/**
	 * Source-newline drop: ignore `Trivial<T>.newlineBefore` and let the cascade
	 * pick a width-driven layout, with per-element leading comments and block-style
	 * trailing comments inlined into the cascade-emitted items so source comments
	 * survive. Sister to `Keep` — the opposite policy on the same axis.
	 *
	 * An anyparse extension the fork's `WrappingType` has no value for, so no corpus
	 * fixture selects it and it reaches the engine only from a JSON config that names
	 * it. It is also the only mode that COLLAPSES a list the source broke — every
	 * other one preserves the source form or only breaks a long one — which is what a
	 * project asking for a canonical single-line layout needs.
	 *
	 * Effective only at the trivia-emit branch (`TriviaSepLowering.triviaSepStarExpr`);
	 * the engine's `shape` switch maps `Ignore → shapeNoWrap` exactly as for `Keep`.
	 */
	final Ignore = 6;

	/**
	 * Leading break, then ALL-OR-NOTHING packing: the open delim always
	 * breaks, the items then share ONE continuation line when they fit at
	 * that indent, and otherwise take one line each. No partial packing —
	 * which is the whole point, since a half-filled continuation line puts
	 * the breaks at arbitrary places and the reader can no longer scan the
	 * list by eye.
	 *
	 * Wadler's plain group semantics for a delimited list, and the missing
	 * middle between the two neighbours: `FillLine*` packs greedily and
	 * will happily leave a ragged `a, b, c,` / `d` pair of lines, while
	 * `OnePerLine` never uses the continuation line even when everything
	 * fits on it.
	 *
	 * An item carrying a forced hardline (a multi-line nested list, a block
	 * body) takes the one-per-line branch unconditionally — the packed line
	 * it promises would already be several, and the renderer's own fit
	 * probe cannot settle that (it re-flattens the nested list's `Group`).
	 *
	 * anyparse extension — the fork has no `WrappingType` counterpart, so
	 * no corpus fixture can select it; it reaches the engine only from a
	 * JSON config that names it (`"packedOrOnePerLine"`).
	 */
	final PackedOrOnePerLine = 7;

}

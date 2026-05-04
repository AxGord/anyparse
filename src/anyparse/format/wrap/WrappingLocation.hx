package anyparse.format.wrap;

/**
 * Operator placement axis for chain emission shapes that break across
 * lines (`OnePerLineAfterFirst`, `OnePerLine`, `FillLine`).
 *
 *  - `BeforeLast` — operator prefixes the next operand on a continuation
 *    line. The continuation line starts with `op operand`. Matches
 *    haxe-formatter's `wrappingLocation: beforeLast` for `opBoolChain` /
 *    `opAddSubChain` defaults: `dirty = dirty\n\t|| (X)\n\t|| (Y)`.
 *  - `AfterLast` — operator suffixes the previous operand. The previous
 *    line ends with ` op` and the next operand starts the continuation
 *    line. Matches `wrappingLocation: afterLast` (the typedef-level
 *    default in haxe-formatter): `dirty = dirty || (X) ||\n\t(Y)`.
 *
 * The shape selects WHERE the line breaks; the location selects WHICH
 * SIDE OF THE BREAK the operator lands on. The two axes are orthogonal.
 *
 * Mirrors haxe-formatter's `WrappingLocation` enum
 * (`src/formatter/config/WrapConfig.hx`).
 */
enum abstract WrappingLocation(Int) {

	final BeforeLast = 0;

	final AfterLast = 1;
}

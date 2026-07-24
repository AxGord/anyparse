package anyparse.format;

/**
 * Policy for uniform blank-line runs inside a single statement block
 * (function / if / for / while / plain-block bodies — NOT class /
 * interface / abstract member lists, whose spacing is owned by the
 * member-order / classEmptyLines machinery).
 *
 * Rationale: "separators that separate everything separate nothing."
 * When blank lines fall between EVERY adjacent statement pair in a
 * block, they carry no grouping information — they are uniform noise, so
 * `Collapse` removes them all. When the blanks are SELECTIVE (some
 * adjacent pairs sit together, some are split by a blank), they express
 * deliberate semantic groups, and `Collapse` leaves the block untouched,
 * byte-exact.
 *
 * `Keep`     — respect the source's blank lines exactly (pre-slice
 * default; round-trip byte-identical).
 * `Collapse` — when every interior gap between adjacent statements is
 * blank, strip all of them; otherwise leave the block byte-exact.
 *
 * Uniformity is measured over INTERIOR gaps only — the head/tail blanks
 * adjacent to `{` / `}` are owned by `afterLeftCurly` / `beforeRightCurly`
 * and are already resolved before this policy runs. A block with a
 * comment between any of its statements is left untouched: a comment can
 * be a group header, so the grouping intent is unclear and `Collapse`
 * bails.
 *
 * Format-neutral — lives in `anyparse.format` so other grammars with
 * statement blocks can opt into the same policy surface from their own
 * grammar.
 */
enum abstract UniformStatementBlanksPolicy(Int) from Int to Int {

	final Keep = 0;

	final Collapse = 1;

}

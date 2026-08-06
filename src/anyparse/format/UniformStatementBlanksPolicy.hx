package anyparse.format;

/**
 * Policy for uniform blank-line runs inside one delimited element list: a
 * statement block (function / if / for / while / plain-block bodies — NOT
 * class / interface / abstract member lists, whose spacing is owned by the
 * member-order / classEmptyLines machinery), or an array literal.
 *
 * Rationale: "separators that separate everything separate nothing." When
 * blank lines fall between EVERY adjacent pair in a list, they carry no
 * grouping information — they are uniform noise, so `Collapse` removes them
 * all. When the blanks are SELECTIVE (some adjacent pairs sit together, some
 * are split by a blank), they express deliberate semantic groups, and
 * `Collapse` leaves the list untouched, byte-exact.
 *
 * `Keep`     — respect the source's blank lines exactly (pre-slice default;
 * round-trip byte-identical).
 * `Collapse` — when every interior gap between adjacent elements is blank,
 * strip all of them; otherwise leave the list byte-exact.
 *
 * Uniformity is measured over INTERIOR gaps only — the head/tail blanks
 * adjacent to the delimiters are owned by `afterLeftCurly` /
 * `beforeRightCurly` and are already resolved before this policy runs. A
 * list with a leading comment on any element is left untouched: a comment
 * can be a group header, so the grouping intent is unclear and `Collapse`
 * bails.
 *
 * Which lists opt in is a GRAMMAR decision, not a policy one — a field or
 * enum branch carries `@:fmt(uniformStmtBlanks)`. In the Haxe grammar that
 * is the four statement-block Stars plus `HxExpr.ArrayExpr`; object
 * literals, anon types and argument lists deliberately stay out.
 *
 * Collapsing an array-literal gap also drops that gap's hardline
 * requirement, so the literal re-flows exactly as the same source without
 * the blanks would — under a `noWrap` array config that can mean the whole
 * literal collapses onto one line. Without that the emit would not be
 * idempotent.
 *
 * Format-neutral — lives in `anyparse.format` so other grammars with
 * delimited element lists can opt into the same policy surface from their
 * own grammar.
 */
enum abstract UniformStatementBlanksPolicy(Int) from Int to Int {

	final Keep = 0;

	final Collapse = 1;

}

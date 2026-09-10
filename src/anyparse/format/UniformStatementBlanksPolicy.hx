package anyparse.format;

/**
 * Policy for uniform blank-line runs inside ONE delimited element list — a
 * statement block body or an array literal, never a class member list, whose
 * spacing is owned by the member-order / `classEmptyLines` machinery.
 *
 * Separators that separate everything separate nothing: `Collapse` strips the
 * blanks only when EVERY interior gap between adjacent elements is blank, and
 * otherwise leaves the list byte-exact, because selective blanks express
 * deliberate groups; `Keep` respects the source exactly. Uniformity is judged
 * over interior gaps alone — head and tail blanks belong to `afterLeftCurly` /
 * `beforeRightCurly` and are resolved before this policy runs.
 *
 * A leading comment on an INTERIOR element bails the collapse (under uniformity
 * a blank always detaches it from the element above, which is what a group
 * header looks like), while on the FIRST element it cannot be heading a group
 * and collapses with the rest. Collapsing an array-literal gap also drops that
 * gap's hardline requirement, without which the emit would not be idempotent.
 *
 * Which lists opt in is a GRAMMAR decision — a field or enum branch carries
 * `@:fmt(uniformStmtBlanks)`; the policy surface itself is format-neutral.
 */
enum abstract UniformStatementBlanksPolicy(Int) from Int to Int {

	final Keep = 0;

	final Collapse = 1;

}

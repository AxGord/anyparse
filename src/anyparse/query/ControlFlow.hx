package anyparse.query;

/**
 * A grammar's control-flow capability, consumed by the `dead-code` and
 * `empty-block` checks — the seam that keeps the checks grammar-agnostic (mirrors
 * `StringFold.StringFoldSupport`). A grammar with no statement / block concept
 * returns null from `GrammarPlugin.controlFlowSupport` and the checks no-op.
 */
@:nullSafety(Strict)
interface ControlFlowSupport {

	/**
	 * The `QueryNode.kind`s whose direct children form a sequential statement
	 * list — a terminal statement among them makes the following siblings
	 * unreachable.
	 */
	public function blockKinds(): Array<String>;

	/**
	 * Whether `node` is a statement that unconditionally exits its enclosing
	 * block, so any direct sibling after it is unreachable — for a curly-brace
	 * language: `return`, `throw`, and the loop `break` / `continue`.
	 */
	public function isTerminal(node: QueryNode): Bool;

	/**
	 * The `QueryNode.kind`s of a control-flow block (an `if` / `else` / loop /
	 * `try` / `catch` body) that the `empty-block` check flags when the block has
	 * no statements. Kept distinct from `blockKinds()`, which also includes the
	 * function-body kind — an empty function body is idiomatic (an empty `new() {}`
	 * constructor) and is not flagged.
	 */
	public function emptyFlagKinds(): Array<String>;

	/**
	 * The `QueryNode.kind`s whose direct children sit in POSITIONAL slots rather than in a
	 * list — a body a brace-less construct holds exactly one of, a condition, a catch
	 * parameter. Blanking such a child is never "one element fewer": the slot has
	 * to be filled by something, so whatever follows the construct is pulled into it.
	 *
	 * A kind may list OPTIONAL children too — an `else` branch, a second `catch`. What keeps
	 * those from being refused is not this vocabulary but `BodySlotGuard`'s own rule that a
	 * slot whose introducing tokens went with the edit is being reshaped, not emptied; a
	 * grammar whose optional children carry no such leading token would need more than this
	 * list.
	 *
	 * Read by `BodySlotGuard`, the structural half of the writer-emit gate. A grammar with no
	 * such construct returns an empty array and the guard is inert for it.
	 *
	 * Distinct from `blockKinds()` in exactly the way that matters here: a block's children
	 * are a LIST, so removing one leaves a shorter list and means what it says.
	 */
	public function fixedSlotKinds(): Array<String>;

}

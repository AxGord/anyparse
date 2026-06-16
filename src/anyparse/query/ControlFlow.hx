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

}

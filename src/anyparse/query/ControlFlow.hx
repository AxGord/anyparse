package anyparse.query;

/**
 * A grammar's control-flow capability, consumed by the `dead-code` check —
 * the seam that keeps the check grammar-agnostic (mirrors
 * `StringFold.StringFoldSupport`). A grammar with no statement / block concept
 * returns null from `GrammarPlugin.controlFlowSupport` and the check no-ops.
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

}

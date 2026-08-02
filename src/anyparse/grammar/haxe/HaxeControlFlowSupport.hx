package anyparse.grammar.haxe;

import anyparse.query.CondBranchProjection;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.QueryNode;

/**
 * Haxe's control-flow shape for the statement-list checks — `dead-code`, `empty-block` (via
 * `emptyFlagKinds`), and every check that walks `blockKinds()`.
 *
 * Blocks are the three statement-sequence nodes — `BlockBody` (a function body), `BlockStmt` (a
 * nested `{ … }` block) and `BlockExpr` (a block used as an expression) — plus `CondBranch`, the
 * synthetic node `CondBranchProjection.branchAwareTree` wraps one `#if` / `#elseif` / `#else` branch's
 * statement run in. `CondBranch` exists ONLY in the branch-aware projection, so naming it here is
 * inert for a check that stays on the plain tree, and it is what a grammar opts into that
 * projection with. It deliberately does NOT join `emptyFlagKinds` (a branch with no statements is
 * not an empty block a user should be told about).
 *
 * A statement unconditionally exits its block when it is `ReturnStmt` (a value return),
 * `VoidReturnStmt` (a bare `return;`) or `ThrowStmt`, or the dedicated `BreakStmt` / `ContinueStmt`
 * keyword statements.
 */
@:nullSafety(Strict)
final class HaxeControlFlowSupport implements ControlFlowSupport {

	private static final BLOCK_KINDS: Array<String> = ['BlockBody', 'BlockStmt', 'BlockExpr', CondBranchProjection.COND_BRANCH_KIND];
	private static final EMPTY_FLAG_KINDS: Array<String> = ['BlockStmt'];

	public function new() {}

	public function blockKinds(): Array<String> {
		return BLOCK_KINDS;
	}

	public function emptyFlagKinds(): Array<String> {
		return EMPTY_FLAG_KINDS;
	}

	public function isTerminal(node: QueryNode): Bool {
		return switch node.kind {
			case 'ReturnStmt', 'VoidReturnStmt', 'ThrowStmt', 'BreakStmt', 'ContinueStmt': true;
			case _: false;
		};
	}

}

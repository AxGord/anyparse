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

	/**
	 * Every Haxe construct whose body is ONE statement rather than a statement list. The
	 * expression forms sit beside the statement ones because `if` / `for` / `while` / `try`
	 * each have both, and a slot is a slot in either.
	 *
	 * `CaseBranch` is deliberately ABSENT: a `case` arm holds a LIST, so `case 0:` with
	 * nothing in it is a legal arm that does nothing — exactly what removing its only
	 * statement means. `Ternary` is absent for the opposite reason: its branches are
	 * delimited by `?` and `:`, so a blanked branch is a parse error the re-parse gate
	 * already catches rather than a statement silently pulled in.
	 */
	private static final FIXED_SLOT_KINDS: Array<String> = [
		'IfStmt',
		'IfExpr',
		'ForStmt',
		'ForExpr',
		'WhileStmt',
		'WhileExpr',
		'DoWhileStmt',
		'TryCatchStmt',
		'TryCatchStmtBare',
		'TryExpr',
		'CatchClause'
	];

	public function new() {}

	public function blockKinds(): Array<String> {
		return BLOCK_KINDS;
	}

	public function emptyFlagKinds(): Array<String> {
		return EMPTY_FLAG_KINDS;
	}

	public function fixedSlotKinds(): Array<String> {
		return FIXED_SLOT_KINDS;
	}

	public function isTerminal(node: QueryNode): Bool {
		return switch node.kind {
			case 'ReturnStmt', 'VoidReturnStmt', 'ThrowStmt', 'BreakStmt', 'ContinueStmt': true;
			case _: false;
		};
	}

}

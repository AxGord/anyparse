package anyparse.grammar.haxe;

import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.QueryNode;

/**
 * Haxe's control-flow shape for the `dead-code` and `empty-block` checks (the
 * latter via `emptyFlagKinds`). Blocks are the three statement-sequence nodes:
 * `BlockBody` (a function body), `BlockStmt` (a nested `{ … }` block) and
 * `BlockExpr` (a block used as an expression). A statement unconditionally exits
 * its block when it is `ReturnStmt` (a value return), `VoidReturnStmt` (a bare
 * `return;`) or `ThrowStmt`, or the dedicated `BreakStmt` / `ContinueStmt` keyword statements.
 */
@:nullSafety(Strict)
final class HaxeControlFlowSupport implements ControlFlowSupport {

	private static final BLOCK_KINDS: Array<String> = ['BlockBody', 'BlockStmt', 'BlockExpr'];
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

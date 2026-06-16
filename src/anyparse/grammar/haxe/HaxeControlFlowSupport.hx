package anyparse.grammar.haxe;

import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.QueryNode;

/**
 * Haxe's control-flow shape for the `dead-code` and `empty-block` checks (the
 * latter via `emptyFlagKinds`). Blocks are the three statement-sequence nodes:
 * `BlockBody` (a function body), `BlockStmt` (a nested `{ … }` block) and
 * `BlockExpr` (a block used as an expression). A statement unconditionally exits
 * its block when it is `ReturnStmt` (a value return), `VoidReturnStmt` (a bare
 * `return;`) or `ThrowStmt`, or the `break` / `continue` keyword — which parse
 * not as their own kind but as an `ExprStmt` wrapping a bare `IdentExpr` named
 * `break` / `continue`.
 */
@:nullSafety(Strict)
final class HaxeControlFlowSupport implements ControlFlowSupport {

	private static final BLOCK_KINDS: Array<String> = ['BlockBody', 'BlockStmt', 'BlockExpr'];
	private static final JUMP_IDENTS: Array<String> = ['break', 'continue'];
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
			case 'ReturnStmt', 'VoidReturnStmt', 'ThrowStmt': true;
			case 'ExprStmt': isJump(node);
			case _: false;
		};
	}

	/** A `break;` / `continue;` — an `ExprStmt` whose sole child is the bare keyword ident. */
	private static function isJump(stmt: QueryNode): Bool {
		if (stmt.children.length != 1) return false;
		final inner: QueryNode = stmt.children[0];
		final name: Null<String> = inner.name;
		return inner.kind == 'IdentExpr' && name != null && JUMP_IDENTS.contains(name);
	}

}

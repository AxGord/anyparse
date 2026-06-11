package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.QueryNode;

/**
 * Dump-order regression test for the `apq ast` S-expr view of
 * `HxIfStmt`.
 *
 * The AST fields (`thenBody` / `elseBody`) are asserted correct by
 * the green `HxControlFlowSliceTest.testIfElseBlocks` — writer and
 * round-trip are safe. This test pins the **plugin dump layer**:
 * `HaxeQueryPlugin` flattens the `HxIfStmt` struct's fields into the
 * `IfStmt` node's children via `Reflect.fields`, whose iteration
 * order is not guaranteed (V8 vs neko hash order), so the then-body
 * could surface AFTER the else-body. The contract: in `apq ast`
 * child order, the then-body must precede the else-body.
 */
class ApqIfStmtChildOrderTest extends Test {

	public function testIfStmtThenBeforeElseInDump(): Void {
		final src: String = 'class C { function f():Void { if (cnd) thenCall(); else elseCall(); } }';
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(src);
		final ifNode: Null<QueryNode> = findByKind(tree, 'IfStmt');
		Assert.notNull(ifNode, 'expected an IfStmt node in the dump');
		if (ifNode == null) return;

		final thenIdx: Int = firstPreorderIndexOfName(ifNode, 'thenCall');
		final elseIdx: Int = firstPreorderIndexOfName(ifNode, 'elseCall');
		Assert.isTrue(thenIdx >= 0, 'then-body call not found under IfStmt');
		Assert.isTrue(elseIdx >= 0, 'else-body call not found under IfStmt');
		Assert.isTrue(thenIdx < elseIdx, 'then-body must precede else-body in dump child order (thenIdx=$thenIdx, elseIdx=$elseIdx)');
	}

	private static function findByKind(node: QueryNode, kind: String): Null<QueryNode> {
		if (node.kind == kind) return node;
		for (c in node.children) {
			final found: Null<QueryNode> = findByKind(c, kind);
			if (found != null) return found;
		}
		return null;
	}

	/** Pre-order position of the first node whose `name` equals `target`. */
	private static function firstPreorderIndexOfName(root: QueryNode, target: String): Int {
		var counter: Int = -1;
		function walk(n: QueryNode): Int {
			counter++;
			if (n.name == target) return counter;
			for (c in n.children) {
				final hit: Int = walk(c);
				if (hit >= 0) return hit;
			}
			return -1;
		}
		return walk(root);
	}

}

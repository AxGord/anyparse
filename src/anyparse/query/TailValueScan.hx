package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;

/**
 * Every statement list of a tree, each with whether the value of its LAST statement may be used: a block is an
 * expression whose value is its last one, so an edit that changes that statement's type changes the block's. Read top
 * down: a function declaration's body (`blockBodyKind`) uses no value, a statement-position loop (`statementLoopKinds`)
 * none of its body's, a statement other than a list's last none of its own; a conditional, a `switch` with its arms, a
 * `try` with its `catch` clauses and an expression statement hand on what their own position uses; and every other node
 * — an initializer, an argument, a lambda's body — may use what it holds, the conservative answer where no type is read.
 * A macro reification (`opaqueKinds`) is not walked. The one answer to "may the value of a block's last statement be used".
 */
@:nullSafety(Strict)
final class TailValueScan {

	/** Call `visit` on every list of `listKinds` under `tree` with whether its last statement's value may be used. */
	public static function walk(
		tree: QueryNode, shape: RefShape, listKinds: Array<String>, visit: (list:QueryNode, tailUsed:Bool) -> Void
	): Void {
		final passKinds: Array<String> = ShapeVocab.ifKinds(shape)
			.concat(shape.switchKinds ?? [])
			.concat(ShapeVocab.switchArmKinds(shape))
			.concat(ShapeVocab.tryKinds(shape));
		for (k in [shape.catchClauseKind, shape.exprStatementKind]) if (k != null) passKinds.push(k);
		final unusedKinds: Array<String> = ShapeVocab.statementLoopKinds(shape);
		final opaque: Array<String> = shape.opaqueKinds ?? [];
		final bodyKind: Null<String> = shape.blockBodyKind;
		function go(node: QueryNode, used: Bool): Void {
			if (opaque.contains(node.kind)) return;
			final kids: Array<QueryNode> = node.children;
			final list: Bool = listKinds.contains(node.kind);
			final own: Bool = used && node.kind != bodyKind;
			if (list) visit(node, own);
			for (i => kid in kids) {
				final childUsed: Bool = if (list)
					own && i == kids.length - 1
				else if (passKinds.contains(node.kind))
					used
				else
					!unusedKinds.contains(node.kind);
				go(kid, childUsed);
			}
		}
		go(tree, false);
	}

}

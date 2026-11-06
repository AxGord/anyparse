package anyparse.check.scan;

import anyparse.check.scan.PurityScan.PurityCtx;

/**
 * The one answer to "can evaluating this expression throw": a subtree that is a plain value — literals, identifiers,
 * grouping and the pure operators, no field or index read, no call — and whose operators the grammar does not list
 * in `RefShape.faultingOperatorKinds`. A grammar leaving that list unset admits no operator at all.
 *
 * Identifiers are taken to read an initialised variable, so the verdict is about the expression's own operations. A rewrite
 * that interleaves two pure expressions (`filter(p).map(f)` into one loop) changes WHICH exception surfaces only when both
 * can throw, so it needs this of at least one.
 */
@:nullSafety(Strict)
final class ThrowFreeScan {

	/** Whether `node` is a plain value (`PurityScan.isPlainValue`) holding no operator that may fail. */
	public static function isThrowFree(node: QueryNode, ctx: PurityCtx): Bool {
		return PurityScan.isPlainValue(node, ctx) && !holdsFallibleOperator(node, ctx);
	}

	private static function holdsFallibleOperator(node: QueryNode, ctx: PurityCtx): Bool {
		final operators: Array<String> = ctx.shape.pureOperatorKinds ?? [];
		final faulting: Null<Array<String>> = ctx.shape.faultingOperatorKinds;
		return (operators.contains(node.kind) && (faulting == null || faulting.contains(node.kind)))
			|| node.children.exists(c -> holdsFallibleOperator(c, ctx));
	}

}

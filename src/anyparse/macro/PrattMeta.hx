package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;

using Lambda;

/**
 * The operator annotations a Pratt / postfix Alt carries.
 *
 * Three questions about a grammar node — does it have a
 * precedence-carrying branch, does it have a postfix branch, and what
 * operator text does a branch spell — each read straight off
 * `AnnotationKeys`. Both halves of the pipeline ask them: `Lowering`
 * to decide whether to emit a Pratt loop, `WriterLowering` to decide
 * whether to re-emit one. Until this module they were a byte-identical
 * private copy in each.
 */
final class PrattMeta {

	public static function hasPrattBranch(node: ShapeNode): Bool {
		return node.children.exists(
			branch -> branch.annotations.get(AnnotationKeys.PRATT_PREC) != null || branch.annotations.get(AnnotationKeys.TERNARY_OP) != null
		);
	}

	public static function hasPostfixBranch(node: ShapeNode): Bool {
		return node.children.exists(branch -> branch.annotations.get(AnnotationKeys.POSTFIX_OP) != null);
	}

	/** Returns the operator literal for a branch in the Pratt dispatch chain.
	*  Binary infix branches carry `pratt.op`; ternary branches carry `ternary.op`. */

	public static function getOperatorText(branch: ShapeNode): String {
		return (branch.annotations[AnnotationKeys.PRATT_OP]: Null<String>) ?? branch.annotations[AnnotationKeys.TERNARY_OP];
	}

}
#end

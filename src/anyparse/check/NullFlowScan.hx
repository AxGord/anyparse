package anyparse.check;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

/**
 * The seams a null-flow consumer gates on: the equality kinds, the identifier
 * and null-literal kinds, and the `==` kind when the grammar names one.
 */
typedef NullFlowSeams = {
	final equalityKinds: Array<String>;
	final identKind: String;
	final nullLitKind: String;
	final eqKind: Null<String>;
};

/**
 * An identifier operand with its name and the span of the node it sits
 * in — what a flow fact is asked about, and where the finding lands.
 */
typedef IdentOperand = {
	final operand: QueryNode;
	final name: String;
	final span: Span;
};

/**
 * The shapes the `NullFlow.analyze` consumers gate on before asking `facts`: the seams they share, a null
 * comparison's identifier operand, a node's child read as an identifier. Statics over the seams each check
 * already holds — a sibling of `NullFlow`, so the analysis keeps only the lattice.
 */
@:nullSafety(Strict)
final class NullFlowScan {

	/** A comparison has exactly two operands. */
	private static inline final COMPARISON_CHILD_COUNT: Int = 2;

	/** The equality / identifier / null-literal seams, or null when the grammar leaves one unset (the check is then a no-op). */
	public static function seamsOf(shape: RefShape): Null<NullFlowSeams> {
		final equalityKinds: Array<String> = shape.equalityKinds ?? [];
		final identKind: Null<String> = shape.identKind;
		final nullLitKind: Null<String> = shape.nullLiteralKind;
		return equalityKinds.length == 0 || identKind == null || nullLitKind == null ? null : {
			equalityKinds: equalityKinds,
			identKind: identKind,
			nullLitKind: nullLitKind,
			eqKind: shape.eqKind
		};
	}

	/** `node` as an equality of an identifier against the null literal: the identifier, its name and the comparison's span, or null. */
	public static function nullComparedOperand(node: QueryNode, s: NullFlowSeams): Null<IdentOperand> {
		return !s.equalityKinds.contains(node.kind) || node.children.length != COMPARISON_CHILD_COUNT
			? null
			: identOperand(node, NullFlow.nullComparisonOperand(node, s.identKind, s.nullLitKind), s.identKind);
	}

	/** `operand` as a named identifier under `host`'s span, or null when either is missing or `operand` is another kind. */
	public static function identOperand(host: QueryNode, operand: Null<QueryNode>, identKind: String): Null<IdentOperand> {
		final span: Null<Span> = host.span;
		if (operand == null || span == null || operand.kind != identKind) return null;
		final name: Null<String> = operand.name;
		return name == null ? null : { operand: operand, name: name, span: span };
	}

}

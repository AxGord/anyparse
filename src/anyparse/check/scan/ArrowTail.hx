package anyparse.check.scan;

import anyparse.query.ShapeVocab;

/** What the last statement of a function body makes of the function's result once the body is an arrow lambda's. */
enum BodyTail {

	/** Explicit returns pin the inferred result in both forms. */
	Preserving;

	/** The last statement is `Void` by construction, so a value-return elsewhere could not have compiled. */
	VoidTail;

	/** The arrow's implicit return could pick up the last expression's type. */
	Open;

}

/**
 * The one answer to "does a function body keep its result type when it becomes an arrow lambda's body". A `function`
 * whose body ends without a `return` answers `Void`, while an arrow answers its body's last expression, so only a body
 * whose returns pin the result, or whose tail is `Void` by construction, converts with no expected type to prove it.
 */
@:nullSafety(Strict)
final class ArrowTail {

	/**
	 * The body's tail class: `Preserving` when explicit returns pin the inferred type in both forms, `VoidTail` when the
	 * last statement is syntactically `Void`, `Open` when the implicit arrow return could pick up the last expression's
	 * type. A `throw` tail is `Open`: the `function` form is `Void` while the arrow form infers an open monomorph — a
	 * silent drift in generic positions.
	 */
	public static function of(body: QueryNode, shape: RefShape): BodyTail {
		final valueReturns: Array<String> = shape.valueReturnKinds ?? [];
		if (body.kind != shape.blockBodyKind) {
			final expr: Null<QueryNode> = body.children[0];
			return expr != null && valueReturns.contains(expr.kind) ? Preserving : Open;
		}
		if (body.children.length == 0) return VoidTail;
		final last: QueryNode = body.children[body.children.length - 1];
		if (valueReturns.contains(last.kind) || last.kind == shape.voidReturnKind) return Preserving;
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		if (ifKinds.contains(last.kind)) return last.children.length <= 2 ? VoidTail : Open;
		return voidTailKinds(shape).contains(last.kind) ? VoidTail : Open;
	}

	/** Statement kinds that are `Void`-typed by construction when they close a block body. */
	private static function voidTailKinds(shape: RefShape): Array<String> {
		final out: Array<String> = ShapeVocab.statementLoopKinds(shape);
		if (shape.localDeclKinds != null) for (k in shape.localDeclKinds) out.push(k);
		if (shape.localFunctionKinds != null) for (k in shape.localFunctionKinds) out.push(k);
		final empty: Null<String> = shape.emptyStmtKind;
		if (empty != null) out.push(empty);
		return out;
	}

}

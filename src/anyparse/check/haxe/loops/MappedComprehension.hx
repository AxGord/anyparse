package anyparse.check.haxe.loops;

import anyparse.query.BinderScan;

/**
 * The one answer to "is this node a mapping comprehension": `[for (x in xs) body]` — an array literal holding only a loop
 * over a postfix-operand iterable with no value binder — read as its iterable, binder and body. Shared by `prefer-map`,
 * which turns it into `xs.map(…)`, and `identity-map`, which recognises a body that hands the binder back unchanged.
 */
@:nullSafety(Strict)
final class MappedComprehension {

	/** The iterable, the binder and the body when `node` is `[for (x in xs) body]`, else null. */
	public static function of(node: QueryNode, s: ComprehensionSeams): Null<Mapping> {
		if (node.kind != s.arrayLiteralKind || node.children.length != 1) return null;
		final loop: QueryNode = node.children[0];
		final binder: Null<String> = loop.name;
		if (!s.iterationKinds.contains(loop.kind) || binder == null || loop.children.exists(c -> s.valueBinderKinds.contains(c.kind)))
			return null;
		final operands: Array<QueryNode> = BinderScan.loopOperands(loop, s.valueBinderKinds);
		if (operands.length != 2 || !s.operandKinds.contains(operands[0].kind)) return null;
		final iterableSpan: Null<Span> = operands[0].span;
		final bodySpan: Null<Span> = operands[1].span;
		return iterableSpan == null || bodySpan == null ? null : {
			iterable: operands[0],
			body: operands[1],
			binder: binder,
			iterableSpan: iterableSpan,
			bodySpan: bodySpan
		};
	}

	/** Whether `node` is the bare binder, parentheses peeled. */
	public static function isBinder(node: QueryNode, binder: String, s: ComprehensionSeams): Bool {
		var n: QueryNode = node;
		while (n.kind == s.parenKind && n.children.length == 1) n = n.children[0];
		return n.kind == s.identKind && n.name == binder;
	}

	/** The kinds `of` reads, or null when the grammar names no array literal, call or iteration binding. */
	public static function seamsOf(shape: RefShape): Null<ComprehensionSeams> {
		final arrayKind: Null<String> = shape.arrayLiteralKind;
		final callKind: Null<String> = shape.callKind;
		final iterationKinds: Null<Array<String>> = shape.iterationBindingKinds;
		if (arrayKind == null || callKind == null || iterationKinds == null) return null;
		final operandKinds: Array<String> = [shape.identKind, callKind];
		for (k in [shape.fieldAccessKind, shape.indexAccessKind, shape.parenKind]) if (k != null) operandKinds.push(k);
		return {
			arrayLiteralKind: arrayKind,
			identKind: shape.identKind,
			parenKind: shape.parenKind,
			iterationKinds: iterationKinds,
			valueBinderKinds: shape.iterationValueBinderKinds ?? [],
			operandKinds: operandKinds
		};
	}

}

/** The grammar kinds `MappedComprehension.of` reads. */
typedef ComprehensionSeams = {
	final arrayLiteralKind: String;
	final identKind: String;
	final parenKind: Null<String>;
	final iterationKinds: Array<String>;
	final valueBinderKinds: Array<String>;
	final operandKinds: Array<String>;
};

/** A mapping comprehension read apart: what it iterates, the name it binds, the value it yields, and where each is written. */
typedef Mapping = {
	final iterable: QueryNode;
	final body: QueryNode;
	final binder: String;
	final iterableSpan: Span;
	final bodySpan: Span;
};

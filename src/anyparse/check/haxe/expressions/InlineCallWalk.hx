package anyparse.check.haxe.expressions;

/**
 * The one answer to "which calls in this file target a local inline function holding an object literal from inside a
 * short-circuit operand": the inline functions declared so far, per enclosing function, and the calls to them found there.
 * A function literal is its own method, so the operand reading stops at it.
 */
final class InlineCallWalk {

	private final _scopes: Array<Map<String, Bool>> = [];
	private final _shape: RefShape;
	private final _callKind: String;
	private final _literalKind: String;
	private final _inlineKinds: Array<String>;
	private final _shortCircuit: Array<String>;
	private final _file: String;
	private final _out: Array<Violation>;

	public function new(
		shape: RefShape, callKind: String, literalKind: String, inlineKinds: Array<String>, shortCircuit: Array<String>, file: String,
		out: Array<Violation>
	) {
		_shape = shape;
		_callKind = callKind;
		_literalKind = literalKind;
		_inlineKinds = inlineKinds;
		_shortCircuit = shortCircuit;
		_file = file;
		_out = out;
	}

	public function walk(node: QueryNode, inOperand: Bool): Void {
		final scoped: Bool = (_shape.functionKinds ?? []).contains(node.kind);
		if (scoped) _scopes.push([]);
		if (_inlineKinds.contains(node.kind) && _scopes.length > 0 && holdsLiteral(node))
			_scopes[_scopes.length - 1].set(node.name ?? '', true);
		report(node, inOperand);
		final short: Bool = _shortCircuit.contains(node.kind);
		final lambda: Bool = (_shape.lambdaKinds ?? []).contains(node.kind);
		for (i => c in node.children) walk(c, (inOperand && !lambda) || (short && i == 1));
		if (scoped) _scopes.pop();
	}

	private function report(node: QueryNode, inOperand: Bool): Void {
		final span: Null<Span> = node.span;
		final callee: Null<QueryNode> = node.kind == _callKind ? node.children[0] : null;
		if (inOperand && span != null && callee != null && callee.kind == _shape.identKind && declared(callee.name ?? '')) _out.push({
			file: _file,
			span: span,
			rule: JvmShortCircuitInlineLocalFn.RULE_ID,
			severity: Severity.Warning,
			message: '`${callee.name}` is an inline function holding an object literal: the jvm target emits an invalid stack map'
			+ ' for its call in a short-circuit operand; bind the call to a local first'
		});
	}

	private function holdsLiteral(node: QueryNode): Bool {
		return node.kind == _literalKind || node.children.exists(holdsLiteral);
	}

	private function declared(name: String): Bool {
		return _scopes.exists(scope -> scope.exists(name));
	}

}

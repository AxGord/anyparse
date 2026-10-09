package anyparse.check;

import anyparse.check.LockTaint.ChainLists;
import anyparse.query.CallGraph;
import anyparse.query.CondRegionScan;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using Lambda;

/**
 * The `catch` bodies no exception can reach: the `try` around them runs nothing that throws. A positive whitelist of what a body may hold
 * — blocks and expression statements, conditional-compilation regions, literals with no interpolation, comparisons, reads of a binding or
 * a plain field, and calls of a `nonThrowing` entry off a static path (with arguments of the same kinds), a field read off such a call's
 * value — anything else may throw, and the `catch` is a path. A `nonThrowing` entry's word is the project's: the call raises nothing and
 * hands back a value its field reads do not fault on (TM: hxcpp's `sys.FileSystem.stat`, which builds a zeroed record for a missing path;
 * a native prim returning a status code). A call off a value is not one: the value may be null, or computed by something that throws.
 */
@:nullSafety(Strict)
final class DeadCatches {

	/** `<file>:<offset>` of a call site -> whether a dead `catch` holds it. */
	private final _dead: Map<String, Bool> = [];

	private final _graph: CallGraph;
	private final _trees: FunctionTrees;
	private final _shape: RefShape;
	private final _listsOf: (String) -> ChainLists;
	private final _tryKinds: Array<String>;
	private final _blockKinds: Array<String>;

	public function new(graph: CallGraph, trees: FunctionTrees, plugin: GrammarPlugin, listsOf: (String) -> ChainLists) {
		_graph = graph;
		_trees = trees;
		_shape = plugin.refShape();
		_listsOf = listsOf;
		_tryKinds = (_shape.tryStatementKinds ?? []).concat(_shape.tryExpressionKinds ?? []);
		final flow: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		_blockKinds = flow == null ? [] : flow.blockKinds();
	}

	/** Whether the site of `edge` sits in the body of a `catch` whose `try` throws nothing (`throwsNothing`). */
	public function holds(edge: CallEdge): Bool {
		final at: Null<Span> = edge.span;
		if (at == null) return false;
		final key: String = '${edge.file}:${at.from}';
		final known: Null<Bool> = _dead[key];
		if (known != null) return known;
		var node: Null<QueryNode> = _trees.ofFile(edge.file);
		var dead: Bool = false;
		while (node != null && !dead) {
			final kids: Array<QueryNode> = node.children;
			final inner: Null<QueryNode> = kids.find(c -> c.span != null && c.span.from <= at.from && c.span.to >= at.to);
			if (inner == null) break;
			dead = _tryKinds.contains(node.kind) && inner.kind == _shape.catchClauseKind && kids.length > 0
				&& throwsNothing(edge.file, kids[0]);
			node = inner;
		}
		_dead[key] = dead;
		return dead;
	}

	/**
	 * Whether the `try` body `node` of `file` holds only what cannot throw. A literal is inert only with no part but
	 * text (an interpolated string runs what it interpolates), a bare name only where it reads a binding or a plain field
	 * (`plainRead`: a property's getter runs code).
	 */
	private function throwsNothing(file: String, node: QueryNode): Bool {
		final kind: String = node.kind;
		if (kind == _shape.callKind) return nonThrowingCall(file, node);
		if (kind == _shape.fieldAccessKind)
			return node.children.length == 1 && node.children[0].kind == _shape.callKind && nonThrowingCall(file, node.children[0]);
		if (kind == _shape.identKind) return node.children.length == 0 && plainRead(file, node);
		if ((_shape.caseLiteralKinds ?? []).contains(kind) || (_shape.stringLiteralKinds ?? []).contains(kind))
			return node.children.foreach(c -> inertSegment(c.kind));
		final passes: Bool = _blockKinds.contains(kind) || kind == _shape.exprStatementKind || kind == _shape.parenKind
			|| (_shape.comparisonKinds ?? []).contains(kind) || CondRegionScan.isConditionalKind(kind, _shape);
		return passes && node.children.foreach(c -> throwsNothing(file, c));
	}

	/**
	 * Whether the bare name `read` of `file` reads a binding of its function (a local, a parameter) or a plain field of
	 * the running type — never a property with a getter, which runs code, nor a name this does not place.
	 */
	private function plainRead(file: String, read: QueryNode): Bool {
		final name: Null<String> = read.name;
		final scope: Null<ReadScope> = scopeOf(file, read);
		if (name == null || scope == null) return false;
		if (!BareNames.bindsNothing(scope.fn, name, _shape)) return true;
		final type: Null<String> = scope.type;
		return type != null && _graph.types.memberOnChain(type, name) != null && _graph.types.propertyOnChain(type, name) == null;
	}

	/** The function node around `node` of `file` and the type declaring it; null where the graph places no function. */
	private function scopeOf(file: String, node: QueryNode): Null<ReadScope> {
		final at: Null<Span> = node.span;
		final fnId: Null<String> = at == null ? null : _graph.functionAt(file, at.from);
		final fn: Null<QueryNode> = fnId == null ? null : _trees.ofId(fnId);
		return fnId == null || fn == null ? null : { fn: fn, type: _graph.node(fnId)?.typeName };
	}

	/**
	 * Whether the callee `callee` of a call of `file` hands the call nothing that can throw or be null: a bare name (the
	 * running type's own function), or a field read off a static path — a chain of names whose root no binding of the
	 * function and no member of the running type holds (a type, a package). A receiver that is a value is not read.
	 */
	private function staticCallee(file: String, callee: QueryNode): Bool {
		if (callee.kind == _shape.identKind) return true;
		return callee.kind == _shape.fieldAccessKind && callee.children.length == 1 && staticPath(file, callee.children[0]);
	}

	/** Whether `node` of `file` is a static path: a name no binding or member holds, or a field read off one. */
	private function staticPath(file: String, node: QueryNode): Bool {
		if (node.kind == _shape.fieldAccessKind) return node.children.length == 1 && staticPath(file, node.children[0]);
		final name: Null<String> = node.name;
		final scope: Null<ReadScope> = scopeOf(file, node);
		if (node.kind != _shape.identKind || name == null || scope == null) return false;
		final type: Null<String> = scope.type;
		return BareNames.bindsNothing(scope.fn, name, _shape) && (type == null || _graph.types.memberOnChain(type, name) == null);
	}

	/**
	 * Whether the call `call` of `file` is of a `nonThrowing` entry — every target the graph resolves there is one, or,
	 * resolved to none, its callee's name is a bare entry — with arguments that cannot throw either.
	 */
	private function nonThrowingCall(file: String, call: QueryNode): Bool {
		final at: Null<Span> = call.span;
		final callee: Null<QueryNode> = call.children.length > 0 ? call.children[0] : null;
		if (at == null || callee == null) return false;
		final lists: ChainLists = _listsOf(file);
		final fn: Null<String> = _graph.functionAt(file, at.from);
		final targets: Array<String> = fn == null ? [] : [
			for (e in _graph.outEdges(fn)) if (e.kind.isInvocation() && e.span?.from == at.from && e.span?.to == at.to) e.to
		];
		final listed: Bool = targets.length > 0
			? targets.foreach(t -> lists.nonThrowingIds.contains(t))
			: lists.nonThrowingNames.contains(callee.name ?? '');
		return listed && staticCallee(file, callee) && call.children.slice(1).foreach(a -> throwsNothing(file, a));
	}

	/** Whether a part of a string literal of `kind` runs nothing: its text, a `$` written as text. */
	private function inertSegment(kind: String): Bool {
		return kind == _shape.stringInterpTextKind || (_shape.stringInterpInertSegmentKinds ?? []).contains(kind);
	}

}

/** Where a name is read: the function node around it and the type declaring that function (null when the graph names none). */
private typedef ReadScope = {
	final fn: QueryNode;
	final type: Null<String>;
}

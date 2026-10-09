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
 * The `catch` bodies no exception can reach: the `try` around them runs nothing that throws. A positive whitelist of
 * what a body may hold — blocks and expression statements, conditional-compilation regions, literals, comparisons,
 * reads of a name, and calls of a `nonThrowing` entry (with arguments of the same kinds), a field read off such a call's
 * value — anything else may throw, and the `catch` is a path. A `nonThrowing` entry's word is the project's: the call
 * raises nothing and hands back a value its field reads do not fault on (TM: hxcpp's `sys.FileSystem.stat`, which
 * builds a zeroed record for a missing path; a native prim returning a status code).
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

	/** Whether the `try` body `node` of `file` holds only what cannot throw. */
	private function throwsNothing(file: String, node: QueryNode): Bool {
		final kind: String = node.kind;
		if (kind == _shape.callKind) return nonThrowingCall(file, node);
		if (kind == _shape.fieldAccessKind)
			return node.children.length == 1 && node.children[0].kind == _shape.callKind && nonThrowingCall(file, node.children[0]);
		final inert: Bool = kind == _shape.identKind || (_shape.caseLiteralKinds ?? []).contains(kind)
			|| (_shape.stringLiteralKinds ?? []).contains(kind);
		if (inert) return node.children.length == 0 || (_shape.stringLiteralKinds ?? []).contains(kind);
		final passes: Bool = _blockKinds.contains(kind) || kind == _shape.exprStatementKind || kind == _shape.parenKind
			|| (_shape.comparisonKinds ?? []).contains(kind) || CondRegionScan.isConditionalKind(kind, _shape);
		return passes && node.children.foreach(c -> throwsNothing(file, c));
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
		return listed && call.children.slice(1).foreach(a -> throwsNothing(file, a));
	}

}

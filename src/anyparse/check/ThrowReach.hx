package anyparse.check;

import anyparse.check.LockSites.LockEscape;
import anyparse.query.CallGraph;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using Lambda;

/**
 * Which calls of a call graph may raise an exception, for the `thread-safety` finding of a lock left held by a throw.
 * A POSITIVE list, never a guess at what a call might do: a call its site's chain names in `throwers` (a primitive known to
 * raise on a real runtime condition — I/O, a database — mostly with no body to read), and every function making a call to one
 * of those outside the body of a `try` with a `catch`. Nothing else raises: a `throw` reached through a call is not followed,
 * since most are invariant guards that never fire, and every caller of one would be reported; a `throw` in the body holding
 * the lock is the walk's own (`LockWindow`). A function whose callers must expect its exception goes in `throwers` by name.
 *
 * Intercepting is read generously, so as to report less: a `catch` of any type stops everything (a typed one lets the
 * rest through), and a call or a body the graph cannot place in its function's tree raises nothing.
 */
@:nullSafety(Strict)
final class ThrowReach {

	/** Each raising function -> its call toward a `throwers` entry. */
	private final _hops: Map<String, CallEdge> = [];

	private final _graph: CallGraph;
	private final _throwersOf: (String) -> Array<String>;
	private final _trees: FunctionTrees;

	private final _tryKinds: Array<String>;
	private final _catchKind: Null<String>;
	private final _nestedFnKinds: Array<String>;

	/**
	 * Solves the raising functions of `graph`: `throwersOf` names the `throwers` of the chain a file sits under, and
	 * `trees` the function nodes the sites are placed in.
	 */
	public function new(graph: CallGraph, shape: RefShape, throwersOf: (String) -> Array<String>, trees: FunctionTrees) {
		_graph = graph;
		_throwersOf = throwersOf;
		_trees = trees;
		_tryKinds = (shape.tryStatementKinds ?? []).concat(shape.tryExpressionKinds ?? []);
		_catchKind = shape.catchClauseKind;
		_nestedFnKinds = MemberKinds.nestedFunctionKinds(shape);
		solve();
	}

	/** Fills `_hops`: from each call of a `throwers` entry, up every invocation no `catch` of its caller intercepts. */
	private function solve(): Void {
		final queue: Array<String> = [];
		for (edge in _graph.edges) if (edge.kind.isInvocation() && _throwersOf(edge.file).contains(edge.to)) reach(edge, queue);
		var qi: Int = 0;
		while (qi < queue.length) for (edge in _graph.inEdges(queue[qi++])) if (edge.kind.isInvocation()) reach(edge, queue);
	}

	/** Whether the call `edge` may raise: its target is a `throwers` entry of its site's chain, or a raising function. */
	public function raises(edge: CallEdge): Bool {
		return edge.kind.isInvocation() && (_throwersOf(edge.file).contains(edge.to) || _hops.exists(edge.to));
	}

	/** The starts of the calls of `edge`'s function, in its file, that may raise. */
	public function raisingFroms(edge: CallEdge): Array<Int> {
		return [
			for (e in _graph.outEdges(edge.from)) {
				final at: Null<Span> = e.span;
				if (at != null && e.file == edge.file && raises(e)) at.from;
			}
		];
	}

	/** Each of the escape nodes `nodes` of `edge`'s function as a `LockEscape`, sorted by start: a raising call names its edge. */
	public function escapes(edge: CallEdge, nodes: Array<QueryNode>): Array<LockEscape> {
		final escapes: Array<LockEscape> = [];
		for (n in nodes) {
			final at: Null<Span> = n.span;
			if (at == null) continue;
			final span: Span = at;
			final raiser: Null<CallEdge> = _graph.outEdges(edge.from)
				.find(e -> e.file == edge.file && e.span?.from == span.from && raises(e));
			escapes.push({ span: span, raiser: raiser });
		}
		escapes.sort((x, y) -> x.span.from - y.span.from);
		return escapes;
	}

	/** `[to, ..., thrower]` — how the call `edge` raises: the functions it runs down to the `throwers` entry. */
	public function chain(edge: CallEdge): Array<String> {
		final parts: Array<String> = [edge.to];
		var cursor: String = edge.to;
		// the hops are a BFS tree toward the throwers, so the walk ends at one
		while (true) {
			final hop: Null<CallEdge> = _hops[cursor];
			if (hop == null) break;
			parts.push(hop.to);
			cursor = hop.to;
		}
		return parts;
	}

	/** Marks the caller of `edge` raising, through it, when the call raises and no `catch` of the caller intercepts it. */
	private function reach(edge: CallEdge, queue: Array<String>): Void {
		final from: String = edge.from;
		if (_hops.exists(from) || !uncaught(edge)) return;
		_hops[from] = edge;
		queue.push(from);
	}

	/** Whether the site of `edge` sits in its function outside the body of every `try` with a `catch`. */
	private function uncaught(edge: CallEdge): Bool {
		final at: Null<Span> = edge.span;
		var node: Null<QueryNode> = _trees.ofId(edge.from);
		if (at == null) return false;
		while (node != null) {
			final kids: Array<QueryNode> = node.children;
			final inner: Null<QueryNode> = kids.find(c -> c.span != null && c.span.from <= at.from && c.span.to >= at.to);
			if (inner == null) return true;
			if (intercepts(node) && inner == kids[0] || _nestedFnKinds.contains(inner.kind)) return false;
			node = inner;
		}
		return false;
	}

	/** Whether `node` is a `try` with a `catch`: an exception raised in its body (its first child) goes no further. */
	private inline function intercepts(node: QueryNode): Bool {
		return _tryKinds.contains(node.kind) && node.children.exists(k -> k.kind == _catchKind);
	}

}

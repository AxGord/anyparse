package anyparse.check;

import anyparse.check.LockSites.LockAcquire;
import anyparse.query.CallGraph;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using Lambda;

/**
 * What may give a lock back while another function holds it (`MustHeld`): a function that gives it back without
 * having taken it, directly or through calls (`releasersOf`), and — when code an unresolved call may run is among those
 * (`hazard`) — every call the graph resolves to nothing (`blindIn`).
 *
 * A wrapper's or a multi-lock helper's own gives are its callers', each judged where it is called: a crossing release
 * (`LockSites.crossing`) names a wrapper's call where it stands, and a helper's call gives where it is made. A give no
 * thread runs gives nothing back, and one in a function working the lock by any other call of its own (a take, a
 * `tryAcquire`) gives back what it took.
 */
@:nullSafety(Strict)
final class LockReleasers {

	/** Each lock -> the functions that may give it back without having taken it, directly or through calls. */
	private final _releasers: Map<String, Map<String, Bool>> = [];

	/** Each lock -> whether code an unresolved call may run can give it back. */
	private final _hazard: Map<String, Bool> = [];

	/** The functions an unresolved call, or a callback registration, may run — and every function they call. */
	private final _unknownRun: Map<String, Bool> = [];

	/** Each function -> the starts of the calls of its body the graph resolves to nothing; null for a body the tree cannot place. */
	private final _blindIn: Map<String, Null<Array<Int>>> = [];

	private final _graph: CallGraph;
	private final _sites: LockSites;
	private final _states: ThreadStates;
	private final _conditions: EdgeConditions;
	private final _trees: FunctionTrees;
	private final _holds: Array<LockAcquire>;
	private final _callKind: Null<String>;
	private final _functionKinds: Array<String>;

	public function new(
		graph: CallGraph, plugin: GrammarPlugin, trees: FunctionTrees, sites: LockSites, states: ThreadStates, conditions: EdgeConditions,
		holds: Array<LockAcquire>, inertRef: (CallEdge) -> Bool, unresolvedNames: Array<String>
	) {
		_graph = graph;
		_sites = sites;
		_states = states;
		_conditions = conditions;
		_trees = trees;
		_holds = holds;
		final shape: RefShape = plugin.refShape();
		_callKind = shape.callKind;
		_functionKinds = (shape.functionKinds ?? []).concat(MemberKinds.nestedFunctionKinds(shape));
		collectUnknownRun(inertRef, unresolvedNames);
	}

	/** The functions that may give `lock` back without having taken it (`givesUntaken`), and every function calling one. */
	public function releasersOf(lock: String): Map<String, Bool> {
		final known: Null<Map<String, Bool>> = _releasers[lock];
		if (known != null) return known;
		final found: Map<String, Bool> = [];
		_releasers[lock] = found;
		final candidates: Array<CallEdge> = [
			for (c in _sites.crossing) if (c.lock == lock && !_sites.helpers.contains(c.edge.from)) c.edge
		].concat([
			for (g in _sites.gives) if (g.lock == lock && _sites.helpers.contains(g.edge.to)) g.edge
		]);
		final queue: Array<String> = [for (g in candidates) if (givesUntaken(g, lock)) g.from];
		for (id in queue) found[id] = true;
		var qi: Int = 0;
		while (qi < queue.length) for (e in _graph.inEdges(queue[qi++])) if (e.kind.isInvocation() && !found.exists(e.from)) {
			found[e.from] = true;
			queue.push(e.from);
		}
		return found;
	}

	/** Whether code an unresolved call may run (`_unknownRun`) can give `lock` back without having taken it. */
	public function hazard(lock: String): Bool {
		final known: Null<Bool> = _hazard[lock];
		if (known != null) return known;
		var found: Bool = false;
		for (id => _ in releasersOf(lock)) if (_unknownRun.exists(id)) found = true;
		_hazard[lock] = found;
		return found;
	}

	/**
	 * The starts of the calls of `id`'s body the graph resolves to nothing, nested functions aside; null for a body the
	 * tree cannot place, which may call anything anywhere.
	 */
	public function blindIn(id: String): Null<Array<Int>> {
		if (_blindIn.exists(id)) return _blindIn[id];
		final fn: Null<QueryNode> = _trees.ofId(id);
		if (fn == null) {
			_blindIn[id] = null;
			return null;
		}
		final out: Array<Int> = [];
		_blindIn[id] = out;
		final resolved: Array<Int> = [
			for (e in _graph.outEdges(id)) if (e.kind.isInvocation() && e.span != null) e.span.from
		];
		function walk(node: QueryNode): Void {
			if (node != fn && _functionKinds.contains(node.kind)) return;
			final at: Null<Span> = node.span;
			if (node.kind == _callKind && at != null && !resolved.contains(at.from)) out.push(at.from);
			for (c in node.children) walk(c);
		}
		walk(fn);
		return out;
	}

	/**
	 * Whether the give `give` of `lock` runs under some state of its function, and that function works the lock by no
	 * other call of its own.
	 */
	private function givesUntaken(give: CallEdge, lock: String): Bool {
		final id: String = give.from;
		final gives: Array<Null<Int>> = [for (o in _sites.gives) if (o.edge.from == id) o.edge.span?.from];
		final takes: Bool = _holds.exists(a -> a.edge.from == id && a.lock == lock)
			|| _graph.outEdges(id).exists(e -> e.kind == Call && !gives.contains(e.span?.from) && _sites.lockOf(e) == lock);
		return !takes && _states.statesOf(id).exists(s -> _conditions.carried(give, s.valuation, s.ctx) != 0);
	}

	/**
	 * Fills `_unknownRun`: every function a value of which is handed on (a callback), or whose name an unresolved call may
	 * mean, and every function those call.
	 */
	private function collectUnknownRun(inertRef: (CallEdge) -> Bool, unresolvedNames: Array<String>): Void {
		final queue: Array<String> = [];
		for (id => node in _graph.nodes) if (
			unresolvedNames.contains(node.name ?? '') || _graph.inEdges(id).exists(e -> e.kind == Ref && !inertRef(e))
		) {
			_unknownRun[id] = true;
			queue.push(id);
		}
		var qi: Int = 0;
		while (qi < queue.length) for (e in _graph.outEdges(queue[qi++])) if (e.kind.isInvocation() && !_unknownRun.exists(e.to)) {
			_unknownRun[e.to] = true;
			queue.push(e.to);
		}
	}

}

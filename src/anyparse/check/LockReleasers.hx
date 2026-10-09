package anyparse.check;

import anyparse.check.LockSites.LockAcquire;
import anyparse.check.LockSites.LockGive;
import anyparse.query.CallGraph;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using Lambda;

/**
 * What `LockReleasers` asks `MustHeld` of a give: whether a hold and a give work the lock of one
 * object; whether a take runs on every path to an offset after it under a valuation; and every
 * run a function's valuation may stand for.
 */
typedef GiveFacts = {
	final sameObject: (LockAcquire, LockGive) -> Bool;
	final takenBefore: (CallEdge, String, Int) -> Bool;
	final runs: (String, String) -> Array<String>;
}

/**
 * What may give a lock back while another function holds it (`MustHeld`): a function that gives it back without
 * having taken it, directly or through calls (`releasersOf`), and — when code an unresolved call may run is among those
 * (`hazard`) — every call the graph resolves to nothing (`blindIn`).
 *
 * A wrapper's or a multi-lock helper's own gives are its callers', each judged where it is called: a wrapper's
 * call and a helper's call give where they are made. A give no thread runs gives nothing back, and one a take
 * of its lock on the same object runs on every path before, in every run of its function, gives back what it
 * took (`givesUntaken`) — any other may give back a hold begun elsewhere: a `tryAcquire` takes nothing for sure.
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
	private final _inertRef: (CallEdge) -> Bool;

	/** What tells a give that takes back what its function took from one that does not (`MustHeld`). */
	private final _facts: GiveFacts;

	public function new(
		graph: CallGraph, plugin: GrammarPlugin, trees: FunctionTrees, sites: LockSites, states: ThreadStates, conditions: EdgeConditions,
		holds: Array<LockAcquire>, inertRef: (CallEdge) -> Bool, unresolvedNames: Array<String>, facts: GiveFacts
	) {
		_graph = graph;
		_sites = sites;
		_states = states;
		_conditions = conditions;
		_trees = trees;
		_holds = holds;
		_inertRef = inertRef;
		_facts = facts;
		final shape: RefShape = plugin.refShape();
		_callKind = shape.callKind;
		_functionKinds = (shape.functionKinds ?? []).concat(MemberKinds.nestedFunctionKinds(shape));
		collectUnknownRun(inertRef, unresolvedNames);
	}

	/**
	 * Whether the edge `e` of a function may run its target from there: a call, or a value handed on to run
	 * (`U.now(() -> m.release())`) unless nothing runs it from there.
	 */
	public inline function runsFrom(e: CallEdge): Bool {
		return e.kind.isInvocation() || e.kind == Ref && !_inertRef(e);
	}

	/**
	 * The functions that may give `lock` back without having taken it (`givesUntaken`), every function calling one, and
	 * every one handing one on as a value to run (`U.now(() -> m.release())`) unless nothing runs it from there.
	 */
	public function releasersOf(lock: String): Map<String, Bool> {
		final known: Null<Map<String, Bool>> = _releasers[lock];
		if (known != null) return known;
		final found: Map<String, Bool> = [];
		_releasers[lock] = found;
		// a wrapper's or a helper's own give is its callers', each judged where it is called
		final queue: Array<String> = [];
		for (g in _sites.gives) {
			final from: String = g.edge.from;
			if (g.lock == lock && !found.exists(from) && !g.own && !_sites.helpers.contains(from) && givesUntaken(g, lock)) {
				found[from] = true;
				queue.push(from);
			}
		}
		var qi: Int = 0;
		while (qi < queue.length) for (e in _graph.inEdges(queue[qi++])) if (runsFrom(e) && !found.exists(e.from)) {
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
		// by the whole span: a chained call (`self().drop()`) starts where the call it is made on does
		final resolved: Array<String> = [
			for (e in _graph.outEdges(id)) if (e.kind.isInvocation() && e.span != null) '${e.span.from}:${e.span.to}'
		];
		function walk(node: QueryNode): Void {
			if (node != fn && _functionKinds.contains(node.kind)) return;
			final at: Null<Span> = node.span;
			if (node.kind == _callKind && at != null && !resolved.contains('${at.from}:${at.to}')) out.push(at.from);
			for (c in node.children) walk(c);
		}
		walk(fn);
		return out;
	}

	/**
	 * Whether the give `give` of `lock` may give back what its function did not take: under some run of the function,
	 * no take of `lock` on the object it gives it on runs on every path before it (`_takenBefore`), or one such take is given back
	 * on every path between it and `give` already. A take on another object, or on one no path names, takes nothing back. A run is a
	 * state's valuation with each parameter it does not know read as each value it may hold (`MustHeld.runsOf`): a tracked parameter
	 * is never written, so `if (!batch) m.acquire(); … if (!batch) m.release();` takes what it gives under every one.
	 */
	private function givesUntaken(given: LockGive, lock: String): Bool {
		final give: CallEdge = given.edge;
		final id: String = give.from;
		final at: Int = give.span?.from ?? -1;
		final takes: Array<LockAcquire> = [for (a in _holds) if (a.edge.from == id && a.lock == lock) a];
		final others: Array<CallEdge> = [
			for (g in _sites.gives) if (g.edge.from == id && g.lock == lock && g.edge != give) g.edge
		];
		return _states.statesOf(id).exists(s ->
			_facts.runs(id, s.valuation).exists(v -> _conditions.carried(give, v, s.ctx) != 0 && !takes.exists(a -> {
				final taken: Int = a.edge.span?.to ?? at;
				_conditions.carried(a.edge, v, s.ctx) != 0 && _facts.sameObject(a, given) && _facts.takenBefore(a.edge, v, at)
				&& !others.exists(o -> (o.span?.from ?? -1) >= taken && (o.span?.to ?? at + 1) <= at && _facts.takenBefore(o, v, at));
			}))
		);
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

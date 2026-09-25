package anyparse.query;

import anyparse.query.CallGraph.EdgeKind;
import anyparse.runtime.Span;

/**
 * How a `CallGraph` wires constructor runs to the field initializers they execute: a declared constructor
 * runs its own type's `<init>`, and a `new T()` / `super()` whose type declares no constructor runs the
 * generated one — that type's initializers, then its superclass's. Runs are recorded while edges are
 * collected and wired once every file's nodes exist; a run whose chain gains a declaration when the graph
 * grows is re-wired, and no edge is added twice.
 */
@:nullSafety(Strict)
final class ConstructorWiring {

	/** The constructor runs recorded so far. */
	private final _runs: Array<CtorRun> = [];

	/** `from|to|kind|site` of every edge the wiring added -> the file of the site that made it. */
	private final _wired: Map<String, String> = [];

	private final _graph: CallGraph;
	private final _ctorName: String;

	/** How many of `_runs` the last wiring has already processed. */
	private var _wiredRuns: Int = 0;

	public function new(graph: CallGraph, ctorName: String) {
		_graph = graph;
		_ctorName = ctorName;
	}

	/** Record a constructor run for the next wiring. */
	public inline function record(run: CtorRun): Void {
		_runs.push(run);
	}

	/**
	 * Wire every recorded constructor run to the `<init>` nodes it executes: a declared
	 * constructor runs its own type's initializers first, and `new T()` / `super()` on a type
	 * with NO constructor of its own runs the generated one, which runs that type's
	 * initializers before its supertype's constructor. Idempotent, so `addFiles` re-runs it; each new edge goes
	 * through `add`.
	 */
	public function wire(add: (String, String, EdgeKind, String, Null<Span>) -> Void): Void {
		function wiredEdge(from: String, to: String, kind: EdgeKind, file: String, span: Null<Span>): Void {
			final key: String = '$from|$to|${kind.label()}|${span?.from ?? -1}';
			if (_wired.exists(key)) return;
			_wired[key] = CallGraphNames.normalizePath(file);
			add(from, to, kind, file, span);
		}
		for (typeName in _graph.declaringTypes()) {
			final ctor: Null<String> = _graph.ownMember(typeName, _ctorName);
			final init: String = '$typeName.${CallGraph.INIT_NAME}';
			if (ctor != null && _graph.nodes.exists(init)) wiredEdge(ctor, init, EdgeKind.Call, _graph.nodes[ctor]?.file ?? '', null);
		}
		// a run already wired only gains an `<init>` when a file declaring a type on its chain arrived since
		for (i in 0...(_runs.length)) {
			final run: CtorRun = _runs[i];
			if (i >= _wiredRuns || run.chainGrew) {
				for (init in generatedInitsOf(run.typeName)) wiredEdge(run.from, init, run.kind, run.file, run.span);
				// a `new T()` recorded before T's supertype arrived named a placeholder; the inherited constructor runs
				final ctor: Null<String> = _graph.memberOnChain(run.typeName, _ctorName);
				if (run.kind == EdgeKind.New && ctor != null && ctor != run.target && _graph.nodes[ctor]?.isExternal == false)
					wiredEdge(run.from, ctor, EdgeKind.New, run.file, run.span);
				run.chainGrew = false;
			}
		}
		_wiredRuns = _runs.length;
	}

	/** Forget the runs recorded at sites of `file` and the edges wired from them or from one of the `removed` nodes. */
	public function removeFile(file: String, removed: Map<String, Bool>): Void {
		final wiredBefore: Array<CtorRun> = _runs.slice(0, _wiredRuns);
		final kept: Array<CtorRun> = [for (r in _runs) if (CallGraphNames.normalizePath(r.file) != file) r];
		_wiredRuns = [for (r in wiredBefore) if (CallGraphNames.normalizePath(r.file) != file) r].length;
		_runs.resize(0);
		for (r in kept) _runs.push(r);
		for (key in [
			for (k => site in _wired) if (site == file || removed.exists(k.substring(0, k.indexOf('|')))) k
		]) _wired.remove(key);
	}

	/** Mark every recorded constructor run whose superclass chain passes through one of `grown`, so the next wiring re-reads it. */
	public function markGrownChains(grown: Array<String>): Void {
		if (grown.length == 0) return;
		// many runs share a type: each chain is walked once
		final verdicts: Map<String, Bool> = [];
		for (i in 0..._wiredRuns) {
			final run: CtorRun = _runs[i];
			final cached: Null<Bool> = verdicts[run.typeName];
			final grew: Bool = cached ?? chainGrew(run.typeName, grown);
			verdicts[run.typeName] = grew;
			if (grew) run.chainGrew = true;
		}
	}

	/** Whether a type on `typeName`'s superclass chain, itself included, is one of `grown`. */
	private function chainGrew(typeName: String, grown: Array<String>): Bool {
		var t: Null<String> = typeName;
		final seen: Array<String> = [];
		while (t != null && !seen.contains(t)) {
			final current: String = t;
			if (grown.contains(current)) return true;
			seen.push(current);
			t = _graph.types.superclassOf(current);
		}
		return false;
	}

	/**
	 * The `<init>` nodes a constructor run on `typeName` executes BEFORE it reaches a declared
	 * constructor: `typeName` itself and each supertype up the chain that declares NO constructor
	 * (each gets a generated one that runs its initializers and then its supertype's). The first
	 * type that declares one stops the walk — that constructor's own `<init>` edge covers it.
	 */
	private function generatedInitsOf(typeName: String): Array<String> {
		final inits: Array<String> = [];
		var t: Null<String> = typeName;
		final visited: Array<String> = [];
		while (t != null && !visited.contains(t)) {
			final current: String = t;
			visited.push(current);
			if (_graph.ownMember(current, _ctorName) != null) break;
			if (_graph.nodes.exists('$current.${CallGraph.INIT_NAME}')) inits.push('$current.${CallGraph.INIT_NAME}');
			t = _graph.types.superclassOf(current);
		}
		return inits;
	}

}

/**
 * A constructor run recorded at a `new T()` or `super()` site, wired to the `<init>` nodes it executes;
 * `chainGrew` asks the next wiring to re-read it because a type on its chain gained a declaration.
 */
typedef CtorRun = {
	var typeName: String;
	var from: String;
	var kind: EdgeKind;
	var file: String;
	var span: Null<Span>;
	var chainGrew: Bool;

	/**
	 * The node the site's own edge named (null when it named none), so a
	 * re-wiring adds the constructor only when it resolves to another one.
	 */
	var target: Null<String>;
}

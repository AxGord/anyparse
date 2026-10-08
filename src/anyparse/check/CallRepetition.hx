package anyparse.check;

import anyparse.check.LockTaint.ChainLists;
import anyparse.query.CallGraph;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using Lambda;

/**
 * Whether a call may run more than once each time the code around it runs — what turns a call of a short sink
 * (`shortSinks`) long. A call repeats when its site sits in a loop of its function, when it registers a function value
 * with a call that runs it once per element (`iterates`), or when it stays inside a recursion: its caller and its target
 * call each other, directly or through other functions.
 *
 * A loop is a kind the grammar names: `loopStatementKinds`, `doWhileLoopKinds`, `iterationBindingKinds` and
 * `whileExprKind`. Of a loop binding a name (`for`), only the body repeats — the iterable runs once; of any other, every
 * part does (a `while` condition runs once per turn). A function or lambda around the site starts the count afresh,
 * its body running where it is invoked. A site its file's tree cannot place, a call with no site at all but a
 * constructor's run of its field initializers, or a grammar naming no loop kind repeats: nothing proves it does not.
 */
@:nullSafety(Strict)
final class CallRepetition {

	/** The repeating parts of the loops around each placed position, keyed by `<file>:<offset>`; null for one the tree cannot place. */
	private final _loops: Map<String, Null<Array<Span>>> = [];

	/** Each function's recursion component, numbered by the walk; filled on the first question. */
	private final _component: Map<String, Int> = [];

	/** How many functions each recursion component holds. */
	private final _componentSize: Array<Int> = [];

	private final _graph: CallGraph;
	private final _trees: FunctionTrees;
	private final _listsOf: (String) -> ChainLists;
	private final _loopKinds: Array<String>;
	private final _bindingKinds: Array<String>;

	/** The kinds whose body is a function of its own: a site inside one sits in no loop around it. */
	private final _functionKinds: Array<String>;

	public function new(graph: CallGraph, trees: FunctionTrees, shape: RefShape, listsOf: (String) -> ChainLists) {
		_graph = graph;
		_trees = trees;
		_listsOf = listsOf;
		_bindingKinds = shape.iterationBindingKinds ?? [];
		_loopKinds = (shape.loopStatementKinds ?? []).concat(shape.doWhileLoopKinds ?? [])
			.concat(_bindingKinds)
			.concat(shape.whileExprKind == null ? [] : [shape.whileExprKind]);
		_functionKinds = (shape.functionKinds ?? []).concat(MemberKinds.nestedFunctionKinds(shape));
	}

	/** Whether `edge` may run more than once per run of its function: in a loop, handed to an `iterates` call, or recursive. */
	public function repeated(edge: CallEdge): Bool {
		if (initializerRun(edge)) return false;
		final loops: Null<Array<Span>> = loopsAround(edge);
		return loops == null || loops.length > 0 || iterated(edge) || recursive(edge);
	}

	/**
	 * The functions some path of edges `runs` admits may run more than once per run of where it starts — on ANY such path,
	 * not only one a finding shows: the target of a call or registration that repeats and `runs` admits, and everything
	 * reached from one through edges it admits.
	 */
	public function repeatedFrom(runs: (CallEdge) -> Bool): Map<String, Bool> {
		final found: Map<String, Bool> = [];
		final queue: Array<String> = [];
		for (e in _graph.edges) if (e.kind != Contains && !found.exists(e.to) && runs(e) && repeated(e)) {
			found[e.to] = true;
			queue.push(e.to);
		}
		var qi: Int = 0;
		while (qi < queue.length) for (e in _graph.outEdges(queue[qi++])) if (e.kind != Contains && !found.exists(e.to) && runs(e)) {
			found[e.to] = true;
			queue.push(e.to);
		}
		return found;
	}

	/**
	 * Whether `edge` may run more than once while the lock the call `take` took stays held, both in one function: in a
	 * loop around `edge` that is not around `take`, handed to an `iterates` call, or recursive.
	 */
	public function repeatedUnder(edge: CallEdge, take: CallEdge): Bool {
		if (initializerRun(edge)) return false;
		final loops: Null<Array<Span>> = loopsAround(edge);
		final outer: Null<Array<Span>> = loopsAround(take);
		return loops == null || outer == null || loops.exists(l ->
			!outer.exists(o -> o.from == l.from)
		) || iterated(edge) || recursive(edge);
	}

	/**
	 * Whether the `Ref` edge `edge` hands its value to a call that runs it once per element: one its chain's `iterates`
	 * names — a `Type.member` entry by the graph's target, a bare member name by the name the call is written with.
	 */
	private function iterated(edge: CallEdge): Bool {
		final lists: ChainLists = _listsOf(edge.file);
		return edge.kind == Ref && (lists.iterateIds.contains(edge.via ?? '') || lists.iterateNames.contains(edge.viaMember ?? ''));
	}

	/**
	 * Whether `edge` calls into its own recursion: its target runs its caller again through calls. A registration is no
	 * run: a value handed on runs where the call it is handed to runs it — once per element only for an `iterates` call.
	 */
	private function recursive(edge: CallEdge): Bool {
		// a value handed on runs where the call it is handed to runs it, never at its registration
		if (!edge.kind.isInvocation()) return false;
		if (edge.from == edge.to) return true;
		if (_componentSize.length == 0) components();
		final from: Null<Int> = _component[edge.from];
		return from != null && from == _component[edge.to] && _componentSize[from] > 1;
	}

	/**
	 * The repeating parts of the loops around the site of `edge` in its own function, outermost first; null when the tree
	 * of its file cannot place it, or the grammar names no loop kind.
	 */
	private function loopsAround(edge: CallEdge): Null<Array<Span>> {
		final span: Null<Span> = edge.span;
		return span == null ? null : loopsAt(edge.file, span.from);
	}

	/**
	 * The repeating parts of the loops around the offset `at` of `file`, counted from the innermost function around it,
	 * outermost first — a `for`'s body, any other loop whole; null when the tree of the file cannot place it, or the grammar
	 * names no loop kind.
	 */
	public function loopsAt(file: String, at: Int): Null<Array<Span>> {
		final key: String = '$file:$at';
		if (_loops.exists(key)) return _loops[key];
		final tree: Null<QueryNode> = _trees.ofFile(file);
		final found: Null<Array<Span>> = tree == null || _loopKinds.length == 0 ? null : loopsTo(tree, at);
		_loops[key] = found;
		return found;
	}

	/**
	 * The repeating parts of the loops from the root of `tree` down to the node holding the offset `at`, counted from
	 * the innermost function around it.
	 */
	private function loopsTo(tree: QueryNode, at: Int): Array<Span> {
		var loops: Array<Span> = [];
		var node: QueryNode = tree;
		while (true) {
			final child: Null<QueryNode> = node.children.find(c -> c.span != null && c.span.from <= at && c.span.to > at);
			if (child == null) return loops;
			final span: Null<Span> = node.span;
			final repeating: Null<Span> = _bindingKinds.contains(node.kind) ? node.children[node.children.length - 1].span : span;
			// a function around the site starts it afresh; a lambda that IS the site is a value its own function registers there
			if (_functionKinds.contains(node.kind) && span != null && span.from != at)
				loops = []
			else if (_loopKinds.contains(node.kind) && repeating != null && repeating.from <= at && at < repeating.to)
				loops.push(repeating);
			node = child;
		}
	}

	/** Numbers the strongly connected components of the graph over its runs: calls, constructions, overrides, accessors (Tarjan). */
	private function components(): Void {
		final index: Map<String, Int> = [];
		final low: Map<String, Int> = [];
		final onStack: Map<String, Bool> = [];
		final stack: Array<String> = [];
		var counter: Int = 0;
		for (root in _graph.nodes.keys()) if (!index.exists(root)) {
			final frames: Array<{ id: String, edges: Array<CallEdge>, next: Int }> = [];
			function open(id: String): Void {
				index[id] = counter;
				low[id] = counter;
				counter++;
				stack.push(id);
				onStack[id] = true;
				frames.push({ id: id, edges: [for (e in _graph.outEdges(id)) if (e.kind.isInvocation()) e], next: 0 });
			}
			open(root);
			while (frames.length > 0) {
				final frame: { id: String, edges: Array<CallEdge>, next: Int } = frames[frames.length - 1];
				if (frame.next < frame.edges.length) {
					final to: String = frame.edges[frame.next++].to;
					if (!index.exists(to))
						open(to)
					else if (onStack.exists(to))
						low[frame.id] = Std.int(Math.min(low[frame.id] ?? 0, index[to] ?? 0));
					continue;
				}
				frames.pop();
				if (frames.length > 0) {
					final parent: String = frames[frames.length - 1].id;
					low[parent] = Std.int(Math.min(low[parent] ?? 0, low[frame.id] ?? 0));
				}
				if (low[frame.id] != index[frame.id]) continue;
				final number: Int = _componentSize.length;
				var size: Int = 0;
				while (true) {
					final id: Null<String> = stack.pop();
					if (id == null) break;
					onStack.remove(id);
					_component[id] = number;
					size++;
					if (id == frame.id) break;
				}
				_componentSize.push(size);
			}
		}
	}

	/**
	 * Whether `edge` is a constructor's run of its type's field initializers: once per construction, through an edge with
	 * no site of its own, into a field-initializer pseudo-node (`CallGraph.INIT_NAME`, `CallGraph.STATIC_INIT_NAME`).
	 */
	private function initializerRun(edge: CallEdge): Bool {
		final node: Null<FnNode> = _graph.node(edge.to);
		return edge.span == null && node != null && node.span == null
			&& (node.name == CallGraph.INIT_NAME || node.name == CallGraph.STATIC_INIT_NAME);
	}

}

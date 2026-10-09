package anyparse.check;

import anyparse.check.BoundedRepeats.BoundedRepeat;
import anyparse.check.LockTaint.ChainLists;
import anyparse.query.CallGraph;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using Lambda;

/**
 * Whether a call may run more than once each time the code around it runs — what turns a call of a short sink
 * (`shortSinks`) long. A call repeats when its site sits in a loop of its function, when it hands a function value to a
 * call that may run it more than once, or when it stays inside a recursion: its caller and its target call each other,
 * directly or through other functions.
 *
 * Positive: a value handed to a call repeats unless its chain lists the call as running it at most once (`runsOnce`),
 * keeping it to run per event (`registers`, the runtime's own — a registration into project code is not), running it on
 * another thread (`spawns`, `marshals`) or never (`neverInvokes`); `iterates` names a call that repeats it whatever else
 * lists it. A value stored, or handed to a call the graph resolves to nothing, repeats.
 *
 * A value handed to a `registers` call runs later as a run of its own, once per event however often it was registered:
 * the repeating caller that owns a short call below it (`MainRepeats.climb`) is never one up the registration — neither
 * a loop around it nor anything up the way to it.
 *
 * A loop is a kind the grammar names: `loopStatementKinds`, `doWhileLoopKinds`, `iterationBindingKinds` and
 * `whileExprKind`. Of a loop binding a name (`for`), only the body repeats — the iterable runs once; of any other, every
 * part does (a `while` condition runs once per turn). A function or lambda around the site starts the count afresh,
 * its body running where it is invoked. A site its file's tree cannot place, a call with no site at all but a
 * constructor's run of its field initializers, or a grammar naming no loop kind repeats: nothing proves it does not.
 *
 * A `boundedRepeats` entry binds ONE repetition of one member's code (`BoundedRepeats`): a call every repetition of
 * which an entry binds runs as once while the product of their bounds times the worst cost of a turn stays under
 * `repeatBudgetMs`.
 */
@:nullSafety(Strict)
final class CallRepetition {

	/** The repeating parts of the loops around each placed position, keyed by `<file>:<offset>`; null for one the tree cannot place. */
	private final _loops: Map<String, Null<Array<Span>>> = [];

	/** Each function's recursion component, numbered by the walk; filled on the first question. */
	private final _component: Map<String, Int> = [];

	/** How many functions each recursion component holds. */
	private final _componentSize: Array<Int> = [];

	/** The repetitions the `boundedRepeats` entries of each chain bind (`boundSources`), by the chain's entry list. */
	private final _bindings: Array<{ entries: Array<BoundedRepeat>, sources: Map<String, BoundedRepeat> }> = [];

	/** Each function of the graph with the member it belongs to (`ThreadSafety.memberOf`); filled on the first question. */
	private final _members: Array<{ id: String, member: String }> = [];

	/** Why `boundedRepeats` entries bind nothing (`notices`). */
	private final _notices: Array<String> = [];

	private final _graph: CallGraph;
	private final _trees: FunctionTrees;
	private final _listsOf: (String) -> ChainLists;
	private final _loopKinds: Array<String>;
	private final _bindingKinds: Array<String>;
	private final _doWhileKinds: Array<String>;

	/** The kinds whose body is a function of its own: a site inside one sits in no loop around it. */
	private final _functionKinds: Array<String>;

	public function new(graph: CallGraph, trees: FunctionTrees, shape: RefShape, listsOf: (String) -> ChainLists) {
		_graph = graph;
		_trees = trees;
		_listsOf = listsOf;
		_bindingKinds = shape.iterationBindingKinds ?? [];
		_doWhileKinds = shape.doWhileLoopKinds ?? [];
		_loopKinds = loopKindsOf(shape);
		_functionKinds = (shape.functionKinds ?? []).concat(MemberKinds.nestedFunctionKinds(shape));
	}

	/**
	 * The loops of `shape` — `loopStatementKinds`, `doWhileLoopKinds`, `iterationBindingKinds` and `whileExprKind`, each
	 * once: the one definition of a loop every check of repetition and control flow reads (`ErrorPaths`, `LockWindow`).
	 */
	public static function loopKindsOf(shape: RefShape): Array<String> {
		final kinds: Array<String> = [];
		final all: Array<String> = (shape.loopStatementKinds ?? []).concat(shape.doWhileLoopKinds ?? [])
			.concat(shape.iterationBindingKinds ?? [])
			.concat(shape.whileExprKind == null ? [] : [shape.whileExprKind]);
		for (k in all) if (!kinds.contains(k)) kinds.push(k);
		return kinds;
	}

	/** Whether `edge` may run more than once per run of its function: in a loop, handing its value to a call that may repeat it, or recursive. */
	public function repeated(edge: CallEdge): Bool {
		if (initializerRun(edge)) return false;
		final loops: Null<Array<Span>> = loopsAround(edge);
		return loops == null || recursive(edge) || !boundedOnce(edge, sourcesOf(edge, loops));
	}

	/**
	 * Whether the site at the offset `at`, in the function and file of the call `take`, runs at most once per run of
	 * `take`: placed, with no loop around it that is not around `take` too.
	 */
	public function onceUnder(take: CallEdge, at: Int): Bool {
		final loops: Null<Array<Span>> = loopsAt(take.file, at);
		final outer: Null<Array<Span>> = loopsAt(take.file, take.span?.from ?? -1);
		return loops != null && outer != null && !loops.exists(l -> !outer.exists(o -> o.from == l.from));
	}

	/**
	 * Whether `edge` may run more than once while the lock the call `take` took stays held, both in one function: in a
	 * loop around `edge` that is not around `take`, handing its value to a call that may repeat it, or recursive.
	 */
	public function repeatedUnder(edge: CallEdge, take: CallEdge): Bool {
		if (initializerRun(edge)) return false;
		final loops: Null<Array<Span>> = loopsAround(edge);
		final outer: Null<Array<Span>> = loopsAround(take);
		if (loops == null || outer == null || recursive(edge)) return true;
		return !boundedOnce(edge, sourcesOf(edge, loops.filter(l -> !outer.exists(o -> o.from == l.from))));
	}

	/**
	 * Whether the repetitions `sources` of `edge` (`sourcesOf`) run it few enough times, each cheap enough, to run as
	 * once: none, or each one a `boundedRepeats` entry of its chain binds (`boundSources`), the product of their bounds
	 * times the worst cost of one turn under `repeatBudgetMs`.
	 */
	private function boundedOnce(edge: CallEdge, sources: Array<String>): Bool {
		if (sources.length == 0) return true;
		final lists: ChainLists = _listsOf(edge.file);
		final budget: Null<Float> = lists.repeatBudgetMs;
		if (budget == null) return false;
		final bound: Map<String, BoundedRepeat> = boundSources(lists);
		var turns: Float = 1;
		var cost: Float = 0;
		for (s in sources) {
			final entry: Null<BoundedRepeat> = bound[s];
			if (entry == null) return false;
			turns *= entry.max;
			cost = Math.max(cost, entry.costMs);
		}
		return turns * cost < budget;
	}

	/**
	 * Whether the `Ref` edge `edge` hands its value to code that may run it more than once per run of the call: a call
	 * its chain's `iterates` names, and any other but one it lists running the value at most once (`runsOnce`), keeping
	 * it to run once per event (`registered`), running it on another thread (`spawns`, `marshals`) or never
	 * (`neverInvokes`) — a value stored, or handed to a call the graph resolves to nothing, included. Positive: only a
	 * listed call answers once.
	 */
	private function handedOn(edge: CallEdge): Bool {
		if (edge.kind != Ref) return false;
		final lists: ChainLists = _listsOf(edge.file);
		if (listed(edge, lists.iterateIds, lists.iterateNames)) return true;
		final via: String = edge.via ?? '';
		return !(listed(edge, lists.runsOnceIds, lists.runsOnceNames) || registered(edge) || lists.spawnIds.contains(via)
			|| lists.marshalIds.contains(via) || listed(edge, lists.neverInvokeIds, lists.neverInvokeNames));
	}

	/**
	 * Whether the `Ref` edge `edge` hands its value to a call that keeps it to run later, once per event however often it
	 * was registered: one its chain's `registers` names, the runtime's own — a call into a function with a body in the
	 * run's files keeps the value in project code, which runs it from a call the graph cannot follow, as often as it
	 * likes. The value then runs as a run of its own, and nothing up its registration repeats it.
	 */
	public function registered(edge: CallEdge): Bool {
		final lists: ChainLists = _listsOf(edge.file);
		final via: Null<FnNode> = _graph.node(edge.via ?? '');
		return listed(edge, lists.registerIds, lists.registerNames) && (via == null || via.isExternal || via.isBodyless);
	}

	/** Whether the `Ref` edge `edge` hands its value to a call its chain's `marshals` names: it runs on the main thread once per post. */
	public function marshalled(edge: CallEdge): Bool {
		return edge.kind == Ref && _listsOf(edge.file).marshalIds.contains(edge.via ?? '');
	}

	/** Why each `boundedRepeats` entry of a chain the run's files sit under bounds nothing, one line each, deduplicated. */
	public function notices(): Array<String> {
		final seen: Map<String, Bool> = [];
		for (edge in _graph.edges) if (!seen.exists(edge.file)) {
			seen[edge.file] = true;
			final lists: ChainLists = _listsOf(edge.file);
			if (lists.reports) boundSources(lists);
		}
		return _notices;
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
		final found: Null<Array<Span>> = tree == null || _loopKinds.length == 0 ? null : [for (l in loopsTo(tree, at)) l.repeating];
		_loops[key] = found;
		return found;
	}

	/**
	 * The header of the innermost loop around the offset `at` of `file`, counted from the innermost function around it —
	 * `for (s in sessions)`, `while (pending())`, `do … while (more)` — its whitespace collapsed, and a rank (`#2`) for a
	 * second loop of the same header in that function: what names the loop whatever else its body holds, and whatever
	 * moves around it. Null when no loop is placed there.
	 */
	public function loopLabel(file: String, at: Int): Null<String> {
		final tree: Null<QueryNode> = _trees.ofFile(file);
		final loop: Null<QueryNode> = tree == null || _loopKinds.length == 0 ? null : loopsTo(tree, at).pop()?.node;
		return tree == null || loop == null ? null : labelOf(file, tree, loop, at);
	}

	/** The label (`loopLabel`) of the loop node `loop` around the offset `at` of `file`, whose tree is `tree`. */
	private function labelOf(file: String, tree: QueryNode, loop: QueryNode, at: Int): Null<String> {
		final label: Null<String> = header(file, loop);
		if (label == null) return null;
		// a second loop of one header in one function is told apart by its rank among them, never by its offset
		final same: Array<QueryNode> = [for (l in loopsIn(scopeOf(tree, at), true)) if (header(file, l) == label) l];
		final rank: Int = same.indexOf(loop);
		return rank > 0 ? '$label #${rank + 1}' : label;
	}

	/** The innermost function node of `tree` around the offset `at`, counted as `loopsTo` counts; the root when none is. */
	private function scopeOf(tree: QueryNode, at: Int): QueryNode {
		var scope: QueryNode = tree;
		var node: QueryNode = tree;
		while (true) {
			final child: Null<QueryNode> = node.children.find(c -> c.span != null && c.span.from <= at && c.span.to > at);
			if (child == null) return scope;
			final span: Null<Span> = node.span;
			if (_functionKinds.contains(node.kind) && span != null && span.from != at) scope = node;
			node = child;
		}
	}

	/** The loop nodes under `node` in source order, a function nested in it aside (`top`: `node` itself is the function). */
	private function loopsIn(node: QueryNode, top: Bool): Array<QueryNode> {
		if (!top && _functionKinds.contains(node.kind)) return [];
		final out: Array<QueryNode> = _loopKinds.contains(node.kind) ? [node] : [];
		for (c in node.children) for (l in loopsIn(c, false)) out.push(l);
		return out;
	}

	/** The header of the loop node `loop` of `file` (`loopLabel`); null when the file has no source or the loop no parts. */
	private function header(file: String, loop: QueryNode): Null<String> {
		final source: Null<String> = _graph.sourceOf(file);
		final span: Null<Span> = loop.span;
		if (source == null || span == null || loop.children.length == 0) return null;
		final first: Null<Span> = loop.children[0].span;
		final last: Null<Span> = loop.children[loop.children.length - 1].span;
		final text: Null<String> = if (_doWhileKinds.contains(loop.kind))
			first == null ? null : 'do … ' + source.substring(first.to, span.to)
		else
			last == null ? null : source.substring(span.from, last.from);
		return text == null ? null : StringTools.trim(~/\s+/g.replace(text, ' '));
	}

	/**
	 * The loops from the root of `tree` down to the node holding the offset `at`, counted from the innermost function
	 * around it, outermost first, each with its repeating part that holds `at` — a `for`'s body, any other loop whole.
	 */
	private function loopsTo(tree: QueryNode, at: Int): Array<{ node: QueryNode, repeating: Span }> {
		var loops: Array<{ node: QueryNode, repeating: Span }> = [];
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
				loops.push({ node: node, repeating: repeating });
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

	/** Whether the `Ref` edge `edge` hands its value to a call `ids` names by the graph's target, or `names` by the name the call is written with. */
	private static function listed(edge: CallEdge, ids: Array<String>, names: Array<String>): Bool {
		return edge.kind == Ref && (ids.contains(edge.via ?? '') || names.contains(edge.viaMember ?? ''));
	}

	/**
	 * The repetitions of `edge` in its own function: each loop of `loops` around its site, and the call it hands its
	 * value to when that may repeat it (`handedOn`) — keyed by where each sits.
	 */
	private function sourcesOf(edge: CallEdge, loops: Array<Span>): Array<String> {
		final out: Array<String> = [for (l in loops) loopKey(edge.file, l)];
		if (handedOn(edge)) out.push(handKey(edge));
		return out;
	}

	private static inline function handKey(edge: CallEdge): String {
		return '${edge.file}:hand:${edge.span?.from ?? -1}';
	}

	private static inline function loopKey(file: String, loop: Span): String {
		return '$file:loop:${loop.from}';
	}

	/**
	 * The one repetition each `boundedRepeats` entry of `lists` binds, keyed like `sourcesOf`, resolved the first time
	 * the chain is asked; an entry that binds none, or several, is noted (`notices`) and binds nothing.
	 */
	private function boundSources(lists: ChainLists): Map<String, BoundedRepeat> {
		final known: Null<{ entries: Array<BoundedRepeat>, sources: Map<String, BoundedRepeat> }> = _bindings.find(b ->
			b.entries == lists.bounded
		);
		if (known != null) return known.sources;
		final sources: Map<String, BoundedRepeat> = [];
		if (lists.bounded.length > 0 && lists.repeatBudgetMs == null)
			note('boundedRepeats bounds nothing: `repeatBudgetMs` is not a positive number');
		for (entry in lists.bounded) {
			final problem: Null<String> = bind(entry, sources);
			if (problem != null) note('boundedRepeats entry "${entry.site}" dropped: $problem');
		}
		_bindings.push({ entries: lists.bounded, sources: sources });
		return sources;
	}

	/**
	 * Binds the entry `entry` into `sources`: the one repetition in the code of its member — the member and the
	 * functions it defines — or, with `loop`, the loop of that header (`loopLabel`), or, with `call`, the one around the calls into it
	 * (the call handed a value it may repeat, else the innermost loop around the site). Returns why it binds none instead; null once bound.
	 */
	private function bind(entry: BoundedRepeat, sources: Map<String, BoundedRepeat>): Null<String> {
		final member: String = entry.member;
		final calls: Null<Array<String>> = entry.calls;
		final found: Array<String> = [];
		for (id in functionsOf(member)) for (e in _graph.outEdges(id)) if (
			e.kind != Contains && (calls == null || calls.contains(e.to) || e.kind == Ref && calls.contains(e.via ?? ''))
		) {
			final loops: Null<Array<Span>> = loopsAround(e);
			if (loops == null) return 'a call there sits where the tree cannot place it';
			for (k in boundBy(entry, e, loops)) if (!found.contains(k)) found.push(k);
		}
		if (found.length != 1)
			return found.length == 0
				? 'no repetition there to bound'
				: '${found.length} repetitions there, name the loop (`loop`) or the call (`call`) of one';
		if (sources.exists(found[0])) return 'an earlier entry binds the same repetition';
		sources[found[0]] = entry;
		return null;
	}

	/**
	 * The repetitions of the call `e`, in the code of `entry`'s member and inside `loops`, that `entry` may bind: the loop of
	 * its `loop` header; with no `call`, every one (`sourcesOf`); with one, the call it hands a value it may repeat, else
	 * the innermost loop around it.
	 */
	private function boundBy(entry: BoundedRepeat, e: CallEdge, loops: Array<Span>): Array<String> {
		final calls: Null<Array<String>> = entry.calls;
		final loop: Null<String> = entry.loop;
		return if (loop != null)
			namedLoops(e, loop)
		else if (calls == null)
			sourcesOf(e, loops)
		else if (handedOn(e) && calls.contains(e.via ?? ''))
			[handKey(e)]
		else
			[for (l in loops.slice(-1)) loopKey(e.file, l)];
	}

	/**
	 * The keys of the loops around the site of `edge` in its own function whose label (`loopLabel`) is `label`.
	 */
	private function namedLoops(edge: CallEdge, label: String): Array<String> {
		final tree: Null<QueryNode> = _trees.ofFile(edge.file);
		final span: Null<Span> = edge.span;
		if (tree == null || span == null) return [];
		return [
			for (l in loopsTo(tree, span.from)) if (labelOf(edge.file, tree, l.node, span.from) == label) loopKey(edge.file, l.repeating)
		];
	}

	/** `member` and every function defined in its code (`ThreadSafety.memberOf`). */
	private function functionsOf(member: String): Array<String> {
		if (_members.length == 0) for (id => _ in _graph.nodes) _members.push({ id: id, member: ThreadSafety.memberOf(_graph, id) });
		return [for (m in _members) if (m.member == member) m.id];
	}

	private function note(text: String): Void {
		if (!_notices.contains(text)) _notices.push(text);
	}

}

package anyparse.check;

import anyparse.check.BoundedRepeats.BoundedRepeat;
import anyparse.check.LockTaint.ChainLists;
import anyparse.query.CallGraph;
import anyparse.query.GrammarPlugin;
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

	/** A way no `boundedRepeats` entry binds a repetition of yet (`along`). */
	public static final UNBOUNDED: BoundedWay = { turns: 1, cost: 0, entries: [] };

	/** A `boundedRepeats` loop label carrying its rank among the loops of its header (`#2`). */
	private static final RANKED: EReg = ~/ #[0-9]+$/;

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

	/** The loops of the graph's trees: which stand around a position, and what each is called. */
	public final loops: Loops;

	/** The names of the functions of the run's files that have a body (`runtimeCall`), filled on first use. */
	private var _bodiedNames: Null<Map<String, Bool>> = null;

	private final _graph: CallGraph;
	private final _trees: FunctionTrees;
	private final _listsOf: (String) -> ChainLists;

	public function new(graph: CallGraph, trees: FunctionTrees, shape: RefShape, listsOf: (String) -> ChainLists) {
		_graph = graph;
		_trees = trees;
		_listsOf = listsOf;
		loops = new Loops(graph, shape, listsOf);
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
	 * `way` extended by the call `edge` of it, which nothing repeats (`repeated`) or only repetitions `boundedRepeats`
	 * entries bind: their bounds multiply into the way's turns and the worst cost of a turn grows to theirs, judged
	 * against the budget of `edge`'s chain once for the whole way — repetitions in different functions on one way run the
	 * product of their bounds too. Null when that product times the worst turn reaches the budget: the call then repeats.
	 */
	public function along(edge: CallEdge, way: BoundedWay): Null<BoundedWay> {
		final loops: Null<Array<Span>> = loopsAround(edge);
		return initializerRun(edge) || loops == null ? way : extend(edge, sourcesOf(edge, loops), way);
	}

	/**
	 * `along`, for the call `edge` while the lock the call `take` of the same function took stays held: only the
	 * repetitions of `edge` not around `take` too count (`repeatedUnder`).
	 */
	public function alongUnder(edge: CallEdge, take: CallEdge, way: BoundedWay): Null<BoundedWay> {
		final loops: Null<Array<Span>> = loopsAround(edge);
		final outer: Null<Array<Span>> = loopsAround(take);
		if (initializerRun(edge) || loops == null || outer == null) return way;
		return extend(edge, sourcesOf(edge, loops.filter(l -> !outer.exists(o -> o.from == l.from))), way);
	}

	/**
	 * `way` with the repetitions `sources` of `edge` (`sourcesOf`) multiplied in: each one a `boundedRepeats` entry of its
	 * chain binds (`boundSources`), the product of the way's bounds times its worst turn under `repeatBudgetMs`; null
	 * otherwise — the call then repeats.
	 */
	private function extend(edge: CallEdge, sources: Array<String>, way: BoundedWay): Null<BoundedWay> {
		if (sources.length == 0) return way;
		final lists: ChainLists = _listsOf(edge.file);
		final budget: Null<Float> = lists.repeatBudgetMs;
		if (budget == null) return null;
		final bound: Map<String, BoundedRepeat> = boundSources(lists);
		var turns: Float = way.turns;
		var cost: Float = way.cost;
		final entries: Array<BoundedRepeat> = way.entries.copy();
		for (s in sources) {
			final entry: Null<BoundedRepeat> = bound[s];
			if (entry == null) return null;
			turns *= entry.max;
			cost = Math.max(cost, entry.costMs);
			if (!entries.contains(entry)) entries.push(entry);
		}
		return turns * cost < budget ? { turns: turns, cost: cost, entries: entries } : null;
	}

	/**
	 * Whether the repetitions `sources` of `edge` (`sourcesOf`) run it few enough times, each cheap enough, to run as
	 * once: none, or each one a `boundedRepeats` entry of its chain binds (`boundSources`), the product of their bounds
	 * times the worst cost of one turn under `repeatBudgetMs`.
	 */
	private function boundedOnce(edge: CallEdge, sources: Array<String>): Bool {
		return extend(edge, sources, UNBOUNDED) != null;
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
		return !(runsOnce(edge, lists) || registered(edge) || lists.spawnIds.contains(via) || lists.marshalIds.contains(via)
			|| listed(edge, lists.neverInvokeIds, lists.neverInvokeNames));
	}

	/**
	 * Whether the `Ref` edge `edge` hands its value to a call its chain lists running it at most once (`runsOnce`): one a
	 * `Type.member` entry names — the project's word on that member — or one a bare name names that is the runtime's
	 * (`runtimeCall`): a bare name says nothing of a project function of that name, whose body may loop over its items.
	 */
	private function runsOnce(edge: CallEdge, lists: ChainLists): Bool {
		return listed(edge, lists.runsOnceIds, []) || listed(edge, [], lists.runsOnceNames) && runtimeCall(edge);
	}

	/**
	 * Whether the `Ref` edge `edge` is handed to the runtime's call: one the graph resolves to an external or body-less
	 * function, or to none when no function of the run's files with a body bears the name the call is written with — an
	 * unresolved `b.success(f)` may be a project `Batch.success` looping over its items.
	 */
	private function runtimeCall(edge: CallEdge): Bool {
		final via: Null<FnNode> = _graph.node(edge.via ?? '');
		if (via != null) return via.isExternal || via.isBodyless;
		var names: Null<Map<String, Bool>> = _bodiedNames;
		if (names == null) {
			final found: Map<String, Bool> = [];
			for (n in _graph.nodes) if (!n.isExternal && !n.isBodyless && n.name != null) found[n.name] = true;
			_bodiedNames = found;
			names = found;
		}
		return !names.exists(edge.viaMember ?? '');
	}

	/**
	 * Whether the `Ref` edge `edge` hands its value to a call that keeps it to run later, once per event however often it
	 * was registered: one its chain's `registers` names, the runtime's own — a call into a function with a body in the
	 * run's files keeps the value in project code, which runs it from a call the graph cannot follow, as often as it
	 * likes. The value then runs as a run of its own, and nothing up its registration repeats it.
	 */
	public function registered(edge: CallEdge): Bool {
		final lists: ChainLists = _listsOf(edge.file);
		return listed(edge, lists.registerIds, lists.registerNames) && runtimeCall(edge);
	}

	/** Whether the `Ref` edge `edge` hands its value to a call its chain's `marshals` names: it runs on the main thread once per post. */
	public function marshalled(edge: CallEdge): Bool {
		return edge.kind == Ref && _listsOf(edge.file).marshalIds.contains(edge.via ?? '');
	}

	/**
	 * What names the call `edge` with no loop around it, by name, never by position: the call a value is handed to —
	 * with a rank (`#2`) for a second value its function hands that call which may block (`Loops.mayBlock`), as a loop's
	 * label ranks a second loop of its header — else its target; a lambda's positional number (`#3`) is spelled `#fn`.
	 */
	public function handLabel(edge: CallEdge): String {
		final target: String = edge.kind == Ref ? (edge.via ?? edge.viaMember ?? edge.to) : edge.to;
		final named: String = ~/#[0-9]+/g.replace(target, "#fn");
		if (edge.kind != Ref) return named;
		final same: Array<CallEdge> = [
			for (o in _graph.outEdges(edge.from))
				if (o.kind == Ref && (o.via ?? o.viaMember ?? o.to) == target && (o == edge || loops.mayBlock(o.to))) o
		];
		same.sort((a, b) -> (a.span?.from ?? 0) - (b.span?.from ?? 0));
		final rank: Int = same.indexOf(edge);
		return rank > 0 ? '$named #${rank + 1}' : named;
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
		final found: Null<Array<Span>> = tree == null || loops.kinds.length == 0 ? null : [for (l in loops.around(tree, at)) l.repeating];
		_loops[key] = found;
		return found;
	}

	/**
	 * The header of the innermost loop around the offset `at` of `file`, counted from the innermost function around it —
	 * `for (s in sessions)`, `while (pending())`, `do … while (more)` — its whitespace collapsed, and a rank (`#2`) for a
	 * second loop of the same header in that function that repeats a call which may block (`repeatsSink`): what names the
	 * loop whatever else its body holds, whatever moves around it, and whatever loop that blocks nothing is added
	 * beside it. Null when no loop is placed there.
	 */
	public function loopLabel(file: String, at: Int): Null<String> {
		final tree: Null<QueryNode> = _trees.ofFile(file);
		return tree == null ? null : loops.label(file, tree, at);
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
		final loop: Null<String> = entry.loop;
		if (loop != null && !RANKED.match(loop) && labelsIn(member).contains('$loop #2'))
			return 'loop "$loop" names several loops there — add the rank of the one it bounds ("$loop #1", "$loop #2", …)';
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
	 * The keys of the loops around the site of `edge` in its own function whose label (`loopLabel`) is `label` — `#1`
	 * spelling the first of its header, whose label carries no rank.
	 */
	private function namedLoops(edge: CallEdge, label: String): Array<String> {
		final tree: Null<QueryNode> = _trees.ofFile(edge.file);
		final span: Null<Span> = edge.span;
		if (tree == null || span == null) return [];
		final wanted: String = StringTools.endsWith(label, ' #1') ? label.substring(0, label.length - 3) : label;
		return [
			for (l in loops.around(
				tree, span.from
			)) if (loops.labelOf(edge.file, tree, l.node, span.from) == wanted) loopKey(edge.file, l.repeating)
		];
	}

	/** The labels (`loopLabel`) of every loop in the code of `member` — the member and the functions it defines. */
	private function labelsIn(member: String): Array<String> {
		final labels: Array<String> = [];
		for (id in functionsOf(member)) {
			final file: String = _graph.node(id)?.file ?? '';
			final fn: Null<QueryNode> = _trees.ofId(id);
			final tree: Null<QueryNode> = _trees.ofFile(file);
			if (fn != null && tree != null) for (l in loops.within(fn, true)) {
				final label: Null<String> = loops.labelOf(file, tree, l, l.span?.from ?? -1);
				if (label != null) labels.push(label);
			}
		}
		return labels;
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

/**
 * The repetitions `boundedRepeats` entries bind along one way of calls (`CallRepetition.along`): the product of their
 * bounds (`turns`), the worst cost of one turn (`cost`, ms), and the entries met.
 */
typedef BoundedWay = {
	final turns: Float;
	final cost: Float;
	final entries: Array<BoundedRepeat>;
}

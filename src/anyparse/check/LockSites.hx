package anyparse.check;

import anyparse.check.LockWindow.HeldWindow;
import anyparse.query.CallGraph;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using Lambda;

/** One `lockPairs` entry resolved to graph ids: the node that takes the lock and the one that gives it back. */
typedef LockPair = {
	final lockId: String;
	final unlockId: String;
}

/** One call that takes a lock, and what the function it sits in does while holding it. */
typedef LockAcquire = {
	final edge: CallEdge;
	final pair: LockPair;

	/** The lock OBJECT, as the member that holds it (`Owner.field`); null when no sealed member names it. */
	final lock: Null<String>;

	/** Every call of the function the lock may be held at, the acquire and its own releases excepted. */
	final window: Array<CallEdge>;

	/** Whether some path leaves the function still holding the lock — the hold then lasts as long as its caller wants. */
	final leaks: Bool;

	/** Whether the hold sits in the owner's own constructor, on an instance lock, before the object can reach another thread. */
	final uncontended: Bool;
}

/**
 * The lock-discipline facts of one call graph: every call taking a `lockPairs` lock, the lock OBJECT it takes, and the
 * path-aware window it holds that lock across (`LockWindow`).
 *
 * A lock is named by the member it lives in, and only a SEALED member names one: every value it ever holds comes from a
 * `new` (its initializer, an assignment), and every read of it is the receiver of a method call. Anything else — a
 * member read as a value, assigned from a parameter, initialized from another expression — may alias a lock some other
 * name also reaches, so its calls take an UNKNOWN lock. Sealing is judged by NAME over every file of the graph, which
 * can only unseal more.
 */
@:nullSafety(Strict)
final class LockSites {

	public final acquires: Array<LockAcquire> = [];

	/** The locks some function releases without taking them first: held across a function boundary, for as long as anyone likes. */
	public final crossing: Array<String> = [];

	private final _unsealed: Array<String> = [];

	/** Each file's branch-aware tree, projected the first time an acquire in it is traced; null for a file the graph cannot give. */
	private final _trees: Map<String, Null<QueryNode>> = [];

	private final _graph: CallGraph;
	private final _plugin: GrammarPlugin;
	private final _shape: RefShape;
	private final _walker: Null<LockWindow>;
	private final _ctorName: String;

	/** Collects the acquires over the `files` of `graph`; `pairsOf` names the pairs the chain of a file configures. */
	public function new(graph: CallGraph, files: Array<String>, plugin: GrammarPlugin, pairsOf: (String) -> Array<LockPair>) {
		_graph = graph;
		_plugin = plugin;
		_shape = plugin.refShape();
		final flow: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		_walker = flow == null ? null : new LockWindow(_shape, flow);
		_ctorName = _shape.constructorName ?? 'new';
		final takes: Array<{ edge: CallEdge, pair: LockPair }> = [];
		final gives: Array<{ edge: CallEdge, pair: LockPair }> = [];
		for (edge in graph.edges) if (edge.kind == Call) for (pair in pairsOf(edge.file)) {
			if (edge.to == pair.lockId) takes.push({ edge: edge, pair: pair });
			if (edge.to == pair.unlockId) gives.push({ edge: edge, pair: pair });
		}
		collectUnsealed(files, [
			for (t in takes.concat(gives)) if (t.edge.receiverField != null) memberName(t.edge.receiverField)
		]);
		for (take in takes) acquires.push(acquire(take.edge, take.pair, gives));
		collectCrossing(gives);
	}

	/** The lock `edge` is made on: its receiver's member when that member is sealed, else null. */
	public function lockOf(edge: CallEdge): Null<String> {
		final field: Null<String> = edge.receiverField;
		return field == null || _unsealed.contains(memberName(field)) ? null : field;
	}

	private inline function isAccess(kind: String): Bool {
		return kind == _shape.fieldAccessKind || kind == _shape.nullSafeAccessKind || kind == _shape.forceFieldAccessKind;
	}

	private function acquire(edge: CallEdge, pair: LockPair, gives: Array<{ edge: CallEdge, pair: LockPair }>): LockAcquire {
		final lock: Null<String> = lockOf(edge);
		final start: Int = edge.span?.from ?? -1;
		final releases: Array<Int> = [
			for (g in gives) {
				final at: Null<Span> = g.edge.span;
				final other: Null<String> = lockOf(g.edge);
				if (
					at != null && g.pair == pair && g.edge.from == edge.from && g.edge.file == edge.file
					&& (lock == null || other == null || other == lock)
				)
					at.from;
			}
		];
		final fn: Null<QueryNode> = functionNode(edge);
		final traced: Null<HeldWindow> = fn == null || _walker == null || start < 0 ? null : _walker.trace(fn, start, releases);
		final held: Array<CallEdge> = heldEdges(edge, start, releases, traced);
		final leaks: Bool = traced == null || traced.leaks;
		return {
			edge: edge,
			pair: pair,
			lock: lock,
			window: [for (e in held) if (e.kind.isInvocation()) e],
			leaks: leaks,
			uncontended: !leaks && traced != null && lock != null && ownConstructorHold(edge, lock, held, traced)
		};
	}

	/**
	 * Every edge of `edge`'s function whose site `traced` holds the lock at — untraced, every one after the acquire —
	 * the acquire at `start` and the `releases` excepted.
	 */
	private function heldEdges(edge: CallEdge, start: Int, releases: Array<Int>, traced: Null<HeldWindow>): Array<CallEdge> {
		final heldSpans: Array<Span> = traced == null ? [] : [
			for (n in traced.held) {
				final at: Null<Span> = n.span;
				if (at != null) at;
			}
		];
		function heldAt(at: Span): Bool {
			return traced == null ? at.from > start : heldSpans.exists(h -> at.from >= h.from && at.to <= h.to);
		}
		return [
			for (e in _graph.outEdges(edge.from)) {
				final at: Null<Span> = e.span;
				if (e.file == edge.file && at != null && at.from != start && !releases.contains(at.from) && heldAt(at)) e;
			}
		];
	}

	/**
	 * Whether the hold is its owner's constructor taking an INSTANCE lock of the object under construction while that
	 * object has not left it: no function value made, no instance dispatch, no `this` handed anywhere inside the window.
	 */
	private function ownConstructorHold(edge: CallEdge, lock: String, held: Array<CallEdge>, traced: HeldWindow): Bool {
		final fn: Null<FnNode> = _graph.node(edge.from);
		final owner: String = lock.substring(0, lock.lastIndexOf('.'));
		return fn != null && fn.name == _ctorName && fn.typeName == owner && !_graph.types.isStatic(owner, memberName(lock))
			&& !held.exists(e -> e.kind == Ref || e.dispatchType != null) && !traced.held.exists(n -> passesSelf(n, null));
	}

	/** The function node `edge` leaves, found in the branch-aware tree of its file; null when the graph holds no such node. */
	private function functionNode(edge: CallEdge): Null<QueryNode> {
		final span: Null<Span> = _graph.node(edge.from)?.span;
		if (span == null) return null;
		if (!_trees.exists(edge.file)) {
			final tree: Null<QueryNode> = _graph.treeOf(edge.file);
			final source: Null<String> = _graph.sourceOf(edge.file);
			_trees[edge.file] = tree == null || source == null ? null : _plugin.projectBranchAware(tree, source);
		}
		var node: Null<QueryNode> = _trees[edge.file];
		while (node != null) {
			final at: Null<Span> = node.span;
			if (at != null && at.from == span.from && at.to == span.to) return node;
			node = node.children.find(c -> c.span != null && c.span.from <= span.from && c.span.to >= span.to);
		}
		return null;
	}

	/** Whether `node` hands the object under construction to anything — `this` read other than as a member access's receiver. */
	private function passesSelf(node: QueryNode, parent: Null<QueryNode>): Bool {
		return node.kind == _shape.identKind && node.name == _shape.selfReferenceText
			? parent == null || !isAccess(parent.kind) || parent.children[0] != node
			: node.children.exists(c -> passesSelf(c, node));
	}

	/** Every member name among `names` some file of `files` reads as a value or fills from anything but a `new`. */
	private function collectUnsealed(files: Array<String>, names: Array<String>): Void {
		if (names.length == 0) return;
		function walk(node: QueryNode, parent: Null<QueryNode>, grand: Null<QueryNode>): Void {
			final name: Null<String> = node.name;
			if (name != null && names.contains(name) && !_unsealed.contains(name) && !sealedAt(node, parent, grand)) _unsealed.push(name);
			for (c in node.children) walk(c, node, parent);
		}
		for (file in files) {
			final tree: Null<QueryNode> = _graph.treeOf(file);
			if (tree != null) walk(tree, null, null);
		}
	}

	/**
	 * Whether this occurrence of a member name keeps the member sealed: a field declaration initialized by a `new` or not
	 * at all, the receiver of a method call, the target of an assignment from a `new` — or a node that reads no member.
	 */
	private function sealedAt(node: QueryNode, parent: Null<QueryNode>, grand: Null<QueryNode>): Bool {
		if ((_shape.fieldDeclKinds ?? []).contains(node.kind)) {
			final init: Null<QueryNode> = node.children.length == 0 ? null : node.children[node.children.length - 1];
			return init == null || (_shape.typeAnnotationKinds ?? []).contains(init.kind) || init.kind == _shape.newExprKind;
		}
		if (!(node.kind == _shape.identKind || isAccess(node.kind)) || parent == null) return true;
		final receiver: Bool = grand != null && isAccess(parent.kind) && parent.children[0] == node && grand.kind == _shape.callKind
			&& grand.children[0] == parent;
		return receiver || parent.kind == _shape.assignKind && parent.children.length == 2 && parent.children[0] == node
			&& parent.children[1].kind == _shape.newExprKind;
	}

	/** Every lock one of `gives` releases in a function that makes no other call on it: the hold began in another function. */
	private function collectCrossing(gives: Array<{ edge: CallEdge, pair: LockPair }>): Void {
		for (give in gives) {
			final lock: Null<String> = lockOf(give.edge);
			if (lock == null || crossing.contains(lock)) continue;
			// a function that works the lock by any other call of its own (a take, a `tryAcquire`) releases what it took
			final worked: Bool = _graph.outEdges(give.edge.from)
				.exists(e -> e.kind == Call && e.to != give.pair.unlockId && lockOf(e) == lock);
			if (!worked) crossing.push(lock);
		}
	}

	private static inline function memberName(field: String): String {
		return field.substr(field.lastIndexOf('.') + 1);
	}

}

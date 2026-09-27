package anyparse.check;

import anyparse.check.LockWindow.HeldWindow;
import anyparse.query.CallGraph;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;
import anyparse.query.ReachAdmission;
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

	/** Whether the window runs a call the graph resolves to no target — a function value, a dynamic or untyped receiver. */
	final blind: Bool;

	/** Whether the hold sits in the owner's own constructor, on an instance lock, before the object can reach another thread. */
	final uncontended: Bool;

	/** Whether the take is a lock wrapper's own: the hold goes on at each call of the wrapper, an acquire of its own. */
	final delegated: Bool;
}

/** One call that takes or gives back the lock of `pair`: a call of the pair's own member, or of a lock wrapper. */
private typedef LockCall = {
	final edge: CallEdge;
	final pair: LockPair;
}

/**
 * What a lock wrapper does to its one lock: a call of it takes (`takes`) or gives back the `lock` of `pair` — on the
 * object the wrapper runs on (`self`), or on another one.
 */
private typedef LockWrapper = {
	final takes: Bool;
	final lock: Null<String>;
	final pair: LockPair;
	final self: Bool;
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
 *
 * A lock WRAPPER is a function whose whole lock traffic is one call taking a lock on every path in, or one call giving
 * it back on every path — `acquireX() { _m.acquire(); }`. A call of a wrapper is then a take or a give of that lock, the
 * same object or the same unknown one, where it stands, however it names the wrapper (a bare call, another object's,
 * through an interface), and wrappers nest. Only a wrapper every call of which the graph sees counts: no value
 * reference, no unresolved call of its name, no override outside the scope, no call site that may run anything else.
 */
@:nullSafety(Strict)
final class LockSites {

	/** Bound on the wrapper rounds: one per nesting level; a set that has not settled by then counts no wrapper at all. */
	private static inline final WRAPPER_ROUNDS: Int = 16;

	public final acquires: Array<LockAcquire> = [];

	/** The locks some function releases without taking them first: held across a function boundary, for as long as anyone likes. */
	public final crossing: Array<String> = [];

	private final _unsealed: Array<String> = [];

	/** `<file>:<start>` of every call of a wrapper -> the lock the call takes or gives back, null for an unknown one. */
	private final _siteLocks: Map<String, Null<String>> = [];

	/** `<file>:<start>` of every call of a wrapper -> whether the wrapper works the lock of the object it runs on. */
	private final _siteSelf: Map<String, Bool> = [];

	/** Each file's branch-aware tree, projected the first time an acquire in it is traced; null for a file the graph cannot give. */
	private final _trees: Map<String, Null<QueryNode>> = [];

	private final _graph: CallGraph;
	private final _plugin: GrammarPlugin;
	private final _shape: RefShape;
	private final _walker: Null<LockWindow>;
	private final _ctorName: String;
	private final _nestedFnKinds: Array<String>;

	/** The lock wrappers, by function id. */
	private var _wrappers: Map<String, LockWrapper> = [];

	/** Collects the acquires over the `files` of `graph`; `pairsOf` names the pairs the chain of a file configures. */
	public function new(graph: CallGraph, files: Array<String>, plugin: GrammarPlugin, pairsOf: (String) -> Array<LockPair>) {
		_graph = graph;
		_plugin = plugin;
		_shape = plugin.refShape();
		final flow: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		_walker = flow == null ? null : new LockWindow(_shape, flow);
		_ctorName = _shape.constructorName ?? 'new';
		_nestedFnKinds = MemberKinds.nestedFunctionKinds(_shape);
		final takes: Array<LockCall> = [];
		final gives: Array<LockCall> = [];
		final pairIds: Array<String> = [];
		for (file in files)
			for (pair in pairsOf(file))
				for (id in [pair.lockId, pair.unlockId])
					if (!pairIds.contains(id)) pairIds.push(id);
		for (edge in graph.edges) if (edge.kind == Call) for (pair in pairsOf(edge.file)) {
			if (edge.to == pair.lockId) takes.push({ edge: edge, pair: pair });
			if (edge.to == pair.unlockId) gives.push({ edge: edge, pair: pair });
		}
		collectUnsealed(files, [
			for (t in takes.concat(gives)) if (t.edge.receiverField != null) memberName(t.edge.receiverField)
		]);
		for (site in inferWrappers(takes, gives, pairIds)) (site.wrapper.takes ? takes : gives).push(site.call);
		for (take in takes) acquires.push(acquire(take.edge, take.pair, gives));
		collectCrossing(gives);
	}

	/** The lock `edge` is made on: a wrapper call's lock, else its receiver's member when that member is sealed, else null. */
	public function lockOf(edge: CallEdge): Null<String> {
		final site: Null<String> = siteKey(edge);
		if (site != null && _siteLocks.exists(site)) return _siteLocks[site];
		final field: Null<String> = edge.receiverField;
		return field == null || _unsealed.contains(memberName(field)) ? null : field;
	}

	/**
	 * Whether the lock call `edge` provably works the lock of the object its own function runs on: a static lock, a
	 * lock member read bare or off `this`, or a wrapper that does so called bare or on `this`. Anything else — another
	 * object's member, a call through an interface or another receiver — may be any object's lock.
	 */
	public function selfTake(edge: CallEdge): Bool {
		final lock: Null<String> = lockOf(edge);
		if (lock == null) return false;
		if (isStaticLock(lock)) return true;
		final site: Null<String> = siteKey(edge);
		if (site != null && _siteLocks.exists(site)) return _siteSelf[site] == true && selfCall(edge);
		final callee: Null<QueryNode> = calleeOf(edge);
		return callee != null && isAccess(callee.kind) && callee.children.length > 0 && readsOwnMember(callee.children[0]);
	}

	/** Whether the call `edge` runs on the object its own function runs on: a callee named bare or read off `this`. */
	public function selfCall(edge: CallEdge): Bool {
		final callee: Null<QueryNode> = calleeOf(edge);
		return callee != null && readsOwnMember(callee);
	}

	/** Whether `lock` (`Owner.member`) is a static member: one object however it is reached. */
	public function isStaticLock(lock: String): Bool {
		final dot: Int = lock.lastIndexOf('.');
		return dot > 0 && _graph.types.isStatic(lock.substring(0, dot), lock.substring(dot + 1));
	}

	private inline function isAccess(kind: String): Bool {
		return kind == _shape.fieldAccessKind || kind == _shape.nullSafeAccessKind || kind == _shape.forceFieldAccessKind;
	}

	/** Whether `node` names a member of the running object: a bare name, or a member read off `this`. */
	private function readsOwnMember(node: QueryNode): Bool {
		return node.kind == _shape.identKind
			? node.name != _shape.selfReferenceText
			: isAccess(node.kind) && node.children.length > 0 && node.children[0].kind == _shape.identKind
				&& node.children[0].name == _shape.selfReferenceText;
	}

	/** The callee expression of the call `edge` sits at, found by its exact span in the branch-aware tree. */
	private function calleeOf(edge: CallEdge): Null<QueryNode> {
		final at: Null<Span> = edge.span;
		var node: Null<QueryNode> = at == null ? null : functionNode(edge);
		while (node != null && at != null) {
			final span: Null<Span> = node.span;
			if (node.kind == _shape.callKind && span != null && span.from == at.from && span.to == at.to)
				return node.children.length > 0 ? node.children[0] : null;
			node = node.children.find(c -> c.span != null && c.span.from <= at.from && c.span.to >= at.to);
		}
		return null;
	}

	private function acquire(edge: CallEdge, pair: LockPair, gives: Array<LockCall>): LockAcquire {
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
			blind: traced == null || traced.held.exists(n -> runsUnresolved(n, edge, start, releases)),
			uncontended: !leaks && fn != null && lock != null && ownConstructorHold(edge, lock, fn),
			delegated: _wrappers[edge.from]?.takes == true
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
	 * Whether the hold is its owner's constructor taking an INSTANCE lock of the object under construction, which never
	 * leaves it: nowhere in the constructor a function value made, a method of its own type dispatched (on `this`,
	 * written or implicit), the superclass constructor run, or `this` handed to anything — so no other thread can reach the lock while the constructor runs.
	 */
	private function ownConstructorHold(edge: CallEdge, lock: String, body: QueryNode): Bool {
		final fn: Null<FnNode> = _graph.node(edge.from);
		final owner: String = lock.substring(0, lock.lastIndexOf('.'));
		if (fn == null || fn.name != _ctorName || fn.typeName != owner || _graph.types.isStatic(owner, memberName(lock))) return false;
		final superclass: Null<String> = _graph.types.superclassOf(owner);
		return !_graph.outEdges(edge.from)
				.exists(e -> e.kind == Ref || e.dispatchType == owner || superclass != null && _graph.node(e.to)?.typeName == superclass)
			&& !passesSelf(body, null);
	}

	/**
	 * Whether `node` holds a call of `edge`'s function — neither the acquire at `start` nor one of the `releases`, nor
	 * inside a nested function — the graph resolved to no target: it may run anything, a blocking call included.
	 */
	private function runsUnresolved(node: QueryNode, edge: CallEdge, start: Int, releases: Array<Int>): Bool {
		if (_nestedFnKinds.contains(node.kind)) return false;
		final at: Null<Span> = node.span;
		if (
			node.kind == _shape.callKind && at != null && at.from != start && !releases.contains(at.from)
			&& !_graph.outEdges(edge.from).exists(e -> e.kind.isInvocation() && e.span?.from == at.from)
		)
			return true;
		return node.children.exists(c -> runsUnresolved(c, edge, start, releases));
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

	/**
	 * Every member name among `names` some file of `files` reads as a value, fills from anything but a `new`, or calls a
	 * method on through a receiver the graph did not name that member for (`named`: per file, `<call start>:<member>`
	 * for every invocation whose `receiverField` names one).
	 */
	private function collectUnsealed(files: Array<String>, names: Array<String>): Void {
		if (names.length == 0) return;
		final named: Map<String, Array<String>> = [];
		for (e in _graph.edges) {
			final field: Null<String> = e.receiverField;
			final at: Null<Span> = e.span;
			if (field == null || at == null || !e.kind.isInvocation()) continue;
			final keys: Array<String> = named[e.file] ?? [];
			keys.push('${at.from}:${memberName(field)}');
			named[e.file] = keys;
		}
		var calls: Array<String> = [];
		function walk(node: QueryNode, parent: Null<QueryNode>, grand: Null<QueryNode>): Void {
			final name: Null<String> = node.name;
			if (name != null && names.contains(name) && !_unsealed.contains(name) && !sealedAt(node, parent, grand, calls))
				_unsealed.push(name);
			for (c in node.children) walk(c, node, parent);
		}
		for (file in files) {
			final tree: Null<QueryNode> = _graph.treeOf(file);
			calls = named[file] ?? [];
			if (tree != null) walk(tree, null, null);
		}
	}

	/**
	 * Whether this occurrence of a member name keeps the member sealed: a field declaration initialized by a `new` or not
	 * at all, the receiver of a method call the graph names THIS member for (`namedCalls`) — an untyped, cast or
	 * type-parameter receiver names none, and may be any object's member — the target of an assignment from a `new`,
	 * or a node that reads no member.
	 */
	private function sealedAt(node: QueryNode, parent: Null<QueryNode>, grand: Null<QueryNode>, namedCalls: Array<String>): Bool {
		if ((_shape.fieldDeclKinds ?? []).contains(node.kind)) {
			final init: Null<QueryNode> = node.children.length == 0 ? null : node.children[node.children.length - 1];
			return init == null || (_shape.typeAnnotationKinds ?? []).contains(init.kind) || init.kind == _shape.newExprKind;
		}
		if (!(node.kind == _shape.identKind || isAccess(node.kind)) || parent == null) return true;
		final host: QueryNode = parent;
		final call: Null<QueryNode> = grand;
		final receiver: Bool = call != null && isAccess(host.kind) && host.children[0] == node && call.kind == _shape.callKind
			&& call.children[0] == host && namedCalls.contains('${call.span?.from}:${node.name}');
		return receiver || host.kind == _shape.assignKind && host.children.length == 2 && host.children[0] == node
			&& host.children[1].kind == _shape.newExprKind;
	}

	/** Every lock one of `gives` releases in a function that makes no other call on it: the hold began in another function. */
	private function collectCrossing(gives: Array<LockCall>): Void {
		final giveSites: Array<Null<String>> = [for (g in gives) siteKey(g.edge)];
		for (give in gives) {
			final lock: Null<String> = lockOf(give.edge);
			// a wrapper's own release is its callers' release, each judged where it stands
			if (lock == null || crossing.contains(lock) || _wrappers.exists(give.edge.from)) continue;
			// a function that works the lock by any other call of its own (a take, a `tryAcquire`) releases what it took
			final worked: Bool = _graph.outEdges(give.edge.from)
				.exists(e -> e.kind == Call && !giveSites.contains(siteKey(e)) && lockOf(e) == lock);
			if (!worked) crossing.push(lock);
		}
	}

	/**
	 * The lock wrappers of the graph (`_wrappers`, `_siteLocks`) and their calls, grown a nesting level a round: a round
	 * reads the calls of the last round's wrappers as takes and gives, finds the functions whose whole lock traffic is
	 * one of them (`wrapperOf`), and keeps those every call of which it sees (`dropUncovered`). Empty when the rounds do
	 * not settle — every wrapper's own take then leaks as it did.
	 */
	private function inferWrappers(
		takes: Array<LockCall>, gives: Array<LockCall>, pairIds: Array<String>
	): Array<{ call: LockCall, wrapper: LockWrapper }> {
		final unresolvedNames: Array<String> = [for (u in _graph.unresolved) for (n in ReachAdmission.admittedNames(u)) n];
		var wrappers: Map<String, LockWrapper> = [];
		for (_ in 0...WRAPPER_ROUNDS) {
			final sites: Map<String, { call: LockCall, wrapper: LockWrapper }> = wrapperSites(wrappers);
			_siteLocks.clear();
			_siteSelf.clear();
			for (key => site in sites) {
				_siteLocks[key] = site.wrapper.lock;
				_siteSelf[key] = site.wrapper.self;
			}
			final ops: Map<String, Array<{ call: LockCall, takes: Bool }>> = [];
			function add(call: LockCall, takes: Bool): Void {
				final list: Array<{ call: LockCall, takes: Bool }> = ops[call.edge.from] ?? [];
				list.push({ call: call, takes: takes });
				ops[call.edge.from] = list;
			}
			for (t in takes) add(t, true);
			for (g in gives) add(g, false);
			for (site in sites) add(site.call, site.wrapper.takes);
			final next: Map<String, LockWrapper> = [];
			for (id => list in ops) if (list.length == 1 && mayWrap(id, pairIds, unresolvedNames)) {
				final found: Null<LockWrapper> = wrapperOf(list[0].call, list[0].takes);
				if (found != null) next[id] = found;
			}
			dropUncovered(next);
			if (sameWrappers(next, wrappers)) {
				_wrappers = wrappers;
				return [for (site in sites) site];
			}
			wrappers = next;
		}
		_siteLocks.clear();
		_siteSelf.clear();
		return [];
	}

	/**
	 * What the function `call` leaves does, when `call` is its whole lock traffic: taking a lock on every path in
	 * (`LockWindow.runsOnEveryPath`), which it then holds on every way out, or giving one back on every path
	 * (`LockWindow.releasesOnEveryPath`). Null for anything else — a conditional take included, which a caller holding
	 * on from the call on would read as taken where it may not be.
	 */
	private function wrapperOf(call: LockCall, takes: Bool): Null<LockWrapper> {
		final fn: Null<QueryNode> = functionNode(call.edge);
		final at: Null<Span> = call.edge.span;
		final walker: Null<LockWindow> = _walker;
		if (fn == null || at == null || walker == null) return null;
		final wraps: Bool = takes ? walker.runsOnEveryPath(fn, at.from) : walker.releasesOnEveryPath(fn, [at.from]);
		return wraps ? {
			takes: takes,
			lock: lockOf(call.edge),
			pair: call.pair,
			self: selfTake(call.edge)
		} : null;
	}

	/**
	 * Whether every call of the function `id` can be seen: a method with a body, no pair's own member, never read as a
	 * value, reassigned or called by its name through a receiver the graph could not type, and overriding nothing a
	 * type outside the scope declares.
	 */
	private function mayWrap(id: String, pairIds: Array<String>, unresolvedNames: Array<String>): Bool {
		final fn: Null<FnNode> = _graph.node(id);
		final name: Null<String> = fn?.name;
		final type: Null<String> = fn?.typeName;
		if (fn == null || name == null || type == null || fn.isExternal || fn.isBodyless || fn.isDynamic) return false;
		return id.indexOf('#') < 0 && !pairIds.contains(id) && !unresolvedNames.contains(name)
			&& !_graph.inEdges(id).exists(e -> e.kind == Ref) && !_graph.types.supertypesOf(type).exists(t -> declaredOutside(t, name));
	}

	/**
	 * Whether a type on `typeName`'s chain the graph holds no code of declares `member`: code outside the scope may
	 * dispatch to an override of it. A type the index does not hold is taken to declare none, as `ReachAdmission` does.
	 */
	private function declaredOutside(typeName: String, member: String): Bool {
		final owner: Null<String> = _graph.types.declaringTypeOf(typeName, member);
		return owner != null && _graph.ownMember(owner, member) == null;
	}

	/** Drops from `wrappers` every one some call of which is no wrapper call (`wrapperSites`), or that no call reaches. */
	private function dropUncovered(wrappers: Map<String, LockWrapper>): Void {
		var dropped: Bool = true;
		while (dropped) {
			dropped = false;
			final sites: Map<String, { call: LockCall, wrapper: LockWrapper }> = wrapperSites(wrappers);
			for (id in [for (k in wrappers.keys()) k]) {
				final into: Array<CallEdge> = _graph.inEdges(id);
				final covered: Bool = into.length > 0
					&& into.foreach(e -> (e.kind == Call || e.kind == Virtual) && sites.exists(siteKey(e) ?? ''));
				if (covered) continue;
				wrappers.remove(id);
				dropped = true;
			}
		}
	}

	/**
	 * The calls of `wrappers`, by site: each site every invocation of which runs a wrapper doing the same to the same
	 * lock, or a body-less declaration dispatch passes through (an interface member). A site that may run anything
	 * else is no wrapper call.
	 */
	private function wrapperSites(wrappers: Map<String, LockWrapper>): Map<String, { call: LockCall, wrapper: LockWrapper }> {
		final sites: Map<String, { call: LockCall, wrapper: LockWrapper }> = [];
		final refused: Array<String> = [];
		for (id => wrapper in wrappers) for (e in _graph.inEdges(id)) {
			final key: Null<String> = siteKey(e);
			if (key == null || sites.exists(key) || refused.contains(key)) continue;
			final at: Array<CallEdge> = [
				for (o in _graph.outEdges(e.from)) if (o.kind.isInvocation() && siteKey(o) == key) o
			];
			if (at.foreach(o -> sameWrapper(wrappers[o.to], wrapper) || passesThrough(o.to)))
				sites[key] = { call: { edge: at.find(o -> o.kind == Call) ?? e, pair: wrapper.pair }, wrapper: wrapper };
			else
				refused.push(key);
		}
		return sites;
	}

	/** Whether `id` is a body-less declaration of a type with code of its own — an interface or abstract member, never an extern. */
	private function passesThrough(id: String): Bool {
		final fn: Null<FnNode> = _graph.node(id);
		final type: Null<String> = fn?.typeName;
		return fn != null && type != null && fn.isBodyless && !fn.isExternal && !_graph.types.meta.isExtern(type);
	}

	private static inline function sameWrapper(a: Null<LockWrapper>, b: LockWrapper): Bool {
		return a != null && a.takes == b.takes && a.lock == b.lock && a.pair == b.pair && a.self == b.self;
	}

	private static inline function memberName(field: String): String {
		return field.substr(field.lastIndexOf('.') + 1);
	}

	/** `<file>:<start>` of `edge`'s site; null for an edge with no site. */
	private static function siteKey(edge: CallEdge): Null<String> {
		final at: Null<Span> = edge.span;
		return at == null ? null : '${edge.file}:${at.from}';
	}

	private static function sameWrappers(a: Map<String, LockWrapper>, b: Map<String, LockWrapper>): Bool {
		for (id => w in a) if (!sameWrapper(b[id], w)) return false;
		for (id in b.keys()) if (!a.exists(id)) return false;
		return true;
	}

}

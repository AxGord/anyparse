package anyparse.check;

import anyparse.check.LockAliases.Occurrence;
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

	/** Whether the window could not be traced at all (no function node, no control-flow support): `leaks` and `blind` by default. */
	final untraced: Bool;

	/** The calls in the window the graph resolves to no target, which make the hold `blind`; none for an untraced one. */
	final blindCalls: Array<BlindCall>;

	/** Whether the hold sits in the owner's own constructor, on an instance lock, before the object can reach another thread. */
	final uncontended: Bool;

	/** Whether the take is a lock wrapper's own: the hold goes on at each call of the wrapper, an acquire of its own. */
	final delegated: Bool;

	/** Where an exception leaves the function with the lock still held (`HeldWindow.escapes`), in source order. */
	final escapes: Array<LockEscape>;
}

/** A call the graph resolves to no target, by the name its callee is written with, at its site. */
typedef BlindCall = {
	final name: String;
	final span: Span;
}

/** One throw that leaves a function holding a lock: a `throw` (no `raiser`), or a call that may raise (`ThrowReach`). */
typedef LockEscape = {
	final span: Span;
	final raiser: Null<CallEdge>;
}

/** A release of a lock in a function that never took it (`LockSites.crossing`): the lock, and the call giving it back. */
typedef CrossingRelease = {
	final lock: String;
	final edge: CallEdge;
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
 *
 * A lock member may also ALIAS another (`LockAliases`): written once, in its type's constructor, from a
 * parameter every construction passes a read of one other member. Those hand-offs then leave both
 * members sealed, and the alias names the lock of the member it holds: a hold of either is a hold of that
 * lock. No take of an aliased lock counts as on the holder's own object — two members of one object may be two locks.
 */
@:nullSafety(Strict)
final class LockSites {

	/** Bound on the wrapper rounds: one per nesting level; a set that has not settled by then counts no wrapper at all. */
	private static inline final WRAPPER_ROUNDS: Int = 16;

	public final acquires: Array<LockAcquire> = [];

	/**
	 * Every release of a lock in a function that never took it, with the lock: the hold began elsewhere and lasts for as
	 * long as anyone likes. A lock may cross at several sites.
	 */
	public final crossing: Array<CrossingRelease> = [];


	/**
	 * The holds a call of a multi-lock HELPER opens in its caller, one per lock: a function every call of which the
	 * graph sees (`mayWrap`) whose whole lock traffic is two or more takes, each on every path in, and no give —
	 * `acquireBoth() { a.lock(); b.lock(); }` — leaves each lock held from the call on, as a wrapper does one. A helper
	 * whose traffic is gives, each on every path out, gives each back where it is called. Kept apart from `acquires`:
	 * only the lock order and the throw escapes read them.
	 */
	public final helperHolds: Array<LockAcquire> = [];

	private final _unsealed: Array<String> = [];

	/** Each aliased lock member (`Owner.member`) -> the member it holds the lock of, which names the lock of both. */
	private final _aliases: Map<String, String> = [];

	/** The locks some alias names: several members of possibly one object hold them, so no take of one is provably on the holder's own. */
	private final _aliasedLocks: Array<String> = [];

	/** The aliased locks whose member some code writes (`LockAliases.rewritten`). */
	private final _rewrittenLocks: Array<String> = [];

	/** `<file>:<start>` of every call of a wrapper -> the lock the call takes or gives back, null for an unknown one. */
	private final _siteLocks: Map<String, Null<String>> = [];

	/** `<file>:<start>` of every call of a wrapper -> whether the wrapper works the lock of the object it runs on. */
	private final _siteSelf: Map<String, Bool> = [];

	private final _graph: CallGraph;
	private final _trees: FunctionTrees;
	private final _throws: ThrowReach;

	private final _shape: RefShape;
	private final _walker: Null<LockWindow>;
	private final _ctorName: String;
	private final _nestedFnKinds: Array<String>;

	/** The lock wrappers, by function id. */
	private var _wrappers: Map<String, LockWrapper> = [];


	/**
	 * Collects the acquires over the `files` of `graph`; `pairsOf` names the pairs the chain of a file configures,
	 * `throws` the calls that may raise, and `trees` the function nodes the holds are traced through.
	 */
	public function new(
		graph: CallGraph, files: Array<String>, plugin: GrammarPlugin, pairsOf: (String) -> Array<LockPair>, throws: ThrowReach,
		trees: FunctionTrees
	) {
		_graph = graph;
		_throws = throws;
		_trees = trees;
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
		collectUnsealed(files, plugin, [
			for (t in takes.concat(gives)) if (t.edge.receiverField != null) memberName(t.edge.receiverField)
		]);
		final unresolved: Array<String> = [for (u in graph.unresolved) for (n in ReachAdmission.admittedNames(u)) n];
		for (site in inferWrappers(takes, gives, pairIds, unresolved)) (site.wrapper.takes ? takes : gives).push(site.call);
		for (take in takes) {
			final lock: Null<String> = lockOf(take.edge);
			acquires.push(hold(take.edge, take.pair, lock, releasesOf(take.edge, take.pair, lock, gives)));
		}
		collectCrossing(gives);
		collectHelperHolds(takes, gives, pairIds, unresolved);
	}

	public inline function isAccess(kind: String): Bool {
		return kind == _shape.fieldAccessKind || kind == _shape.nullSafeAccessKind || kind == _shape.forceFieldAccessKind;
	}

	/** The lock `edge` is made on: a wrapper call's lock, else its receiver's member when that member is sealed, else null. */
	public function lockOf(edge: CallEdge): Null<String> {
		final site: Null<String> = siteKey(edge);
		if (site != null && _siteLocks.exists(site)) return _siteLocks[site];
		final field: Null<String> = edge.receiverField;
		return field == null || _unsealed.contains(memberName(field)) ? null : _aliases[field] ?? field;
	}

	/**
	 * Whether the lock call `edge` provably works the lock of the object its own function runs on: a static lock, a
	 * lock member read bare or off `this`, or a wrapper that does so called bare or on `this`. Anything else — another
	 * object's member, a call through an interface or another receiver — may be any object's lock.
	 */
	public function selfTake(edge: CallEdge): Bool {
		final lock: Null<String> = lockOf(edge);
		if (lock == null) return false;
		// an alias may hold a value a static member it names has since been given up for
		if (isStaticLock(lock)) return !_rewrittenLocks.contains(lock);
		if (_aliasedLocks.contains(lock)) return false;
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

	/** Whether `node` names a member of the running object: a bare name, or a member read off `this`. */
	public function readsOwnMember(node: QueryNode): Bool {
		return node.kind == _shape.identKind
			? node.name != _shape.selfReferenceText
			: isAccess(node.kind) && node.children.length > 0 && node.children[0].kind == _shape.identKind
				&& node.children[0].name == _shape.selfReferenceText;
	}

	/** The callee expression of the call `edge` sits at, found by its exact span in the branch-aware tree. */
	private function calleeOf(edge: CallEdge): Null<QueryNode> {
		final at: Null<Span> = edge.span;
		var node: Null<QueryNode> = at == null ? null : _trees.ofEdge(edge);
		while (node != null && at != null) {
			final span: Null<Span> = node.span;
			if (node.kind == _shape.callKind && span != null && span.from == at.from && span.to == at.to)
				return node.children.length > 0 ? node.children[0] : null;
			node = node.children.find(c -> c.span != null && c.span.from <= at.from && c.span.to >= at.to);
		}
		return null;
	}

	/** The starts of the `gives` of `pair` in `edge`'s function that may give back `lock` (an unknown one: any of them). */
	private function releasesOf(edge: CallEdge, pair: LockPair, lock: Null<String>, gives: Array<LockCall>): Array<Int> {
		return [
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
	}

	/** The hold of `lock` (`pair`) the call `edge` opens, closed by the calls starting at `releases` on their own paths. */
	private function hold(edge: CallEdge, pair: LockPair, lock: Null<String>, releases: Array<Int>): LockAcquire {
		final start: Int = edge.span?.from ?? -1;
		final fn: Null<QueryNode> = _trees.ofEdge(edge);
		final traced: Null<HeldWindow> = fn == null || _walker == null || start < 0
			? null
			: _walker.trace(fn, start, releases, _throws.raisingFroms(edge));
		final held: Array<CallEdge> = heldEdges(edge, start, releases, traced);
		final leaks: Bool = traced == null || traced.leaks;
		final unresolved: Array<BlindCall> = traced == null ? [] : [
			for (n in traced.held) for (call in unresolvedCalls(n, edge, start, releases)) call
		];
		return {
			edge: edge,
			pair: pair,
			lock: lock,
			window: [for (e in held) if (e.kind.isInvocation()) e],
			leaks: leaks,
			blind: traced == null || unresolved.length > 0,
			untraced: traced == null,
			blindCalls: unresolved,
			uncontended: !leaks && fn != null && lock != null && ownConstructorHold(edge, lock, fn),
			delegated: _wrappers[edge.from]?.takes == true,
			escapes: traced == null ? [] : _throws.escapes(edge, traced.escapes)
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
		if (
			fn == null || fn.name != _ctorName || fn.typeName != owner || _graph.types.isStatic(owner, memberName(lock))
			|| _aliasedLocks.contains(lock)
		)
			return false;
		final superclass: Null<String> = _graph.types.superclassOf(owner);
		return !_graph.outEdges(edge.from)
				.exists(e -> e.kind == Ref || e.dispatchType == owner || superclass != null && _graph.node(e.to)?.typeName == superclass)
			&& !passesSelf(body, null);
	}

	/**
	 * The calls under `node` of `edge`'s function — neither the acquire at `start` nor one of the `releases`, nor inside a nested
	 * function — the graph resolved to no target, each by its callee's name: any of them may run anything, a blocking call included.
	 */
	private function unresolvedCalls(node: QueryNode, edge: CallEdge, start: Int, releases: Array<Int>): Array<BlindCall> {
		if (_nestedFnKinds.contains(node.kind)) return [];
		final out: Array<BlindCall> = [];
		final at: Null<Span> = node.span;
		if (
			at != null && node.kind == _shape.callKind && at.from != start && !releases.contains(at.from)
			&& !_graph.outEdges(edge.from).exists(e -> e.kind.isInvocation() && e.span?.from == at.from)
		) {
			final site: Span = at;
			final callee: Null<String> = node.children.length > 0 ? node.children[0].name : null;
			out.push({ name: callee ?? '?', span: site });
		}
		for (c in node.children) for (call in unresolvedCalls(c, edge, start, releases)) out.push(call);
		return out;
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
	 * for every invocation whose `receiverField` names one) — unless a proven alias (`settleAliases`) accounts for each
	 * such occurrence (`LockAliases`): the member then stays sealed, and an alias names the lock of the member it holds.
	 */
	private function collectUnsealed(files: Array<String>, plugin: GrammarPlugin, names: Array<String>): Void {
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
		final breaking: Map<String, Array<Occurrence>> = [];
		final aliases: LockAliases = new LockAliases(_graph, _shape, this, _ctorName, files, plugin.typeSyntax);
		final walked: Array<String> = [];
		var pending: Array<String> = names;
		// the member an alias holds the lock of is walked too: it must be sealed apart from its hand-offs
		while (pending.length > 0) {
			collectBreaking(files, pending, named, breaking);
			for (n in pending) walked.push(n);
			pending = aliases.propose(breaking).filter(n -> !walked.contains(n));
		}
		aliases.settle(breaking);
		for (target => source in aliases.targets) _aliases[target] = source;
		for (lock in aliases.locks) _aliasedLocks.push(lock);
		for (lock in aliases.rewritten) _rewrittenLocks.push(lock);
		for (name => found in breaking) if (found.exists(o -> !aliases.accounts(o))) _unsealed.push(name);
	}

	/** Adds to `into` every occurrence of a member name among `names` that does not keep its member sealed (`sealedAt`). */
	private function collectBreaking(
		files: Array<String>, names: Array<String>, named: Map<String, Array<String>>, into: Map<String, Array<Occurrence>>
	): Void {
		var calls: Array<String> = [];
		var file: String = '';
		function walk(node: QueryNode, parent: Null<QueryNode>, grand: Null<QueryNode>): Void {
			final name: Null<String> = node.name;
			if (name != null && names.contains(name) && !sealedAt(node, parent, grand, calls)) {
				final found: Array<Occurrence> = into[name] ?? [];
				found.push({ file: file, node: node, parent: parent });
				into[name] = found;
			}
			for (c in node.children) walk(c, node, parent);
		}
		for (f in files) {
			final tree: Null<QueryNode> = _graph.treeOf(f);
			calls = named[f] ?? [];
			file = f;
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

	/**
	 * Every release of `gives` in a function that makes no other call on its lock: the hold began in another function.
	 */
	private function collectCrossing(gives: Array<LockCall>): Void {
		final giveSites: Array<Null<String>> = [for (g in gives) siteKey(g.edge)];
		for (give in gives) {
			final named: Null<String> = lockOf(give.edge);
			// a wrapper's own release is its callers' release, each judged where it stands
			if (named == null || _wrappers.exists(give.edge.from)) continue;
			final lock: String = named;
			// a function that works the lock by any other call of its own (a take, a `tryAcquire`) releases what it took
			final worked: Bool = _graph.outEdges(give.edge.from)
				.exists(e -> e.kind == Call && !giveSites.contains(siteKey(e)) && lockOf(e) == lock);
			if (!worked) crossing.push({ lock: lock, edge: give.edge });
		}
	}

	/**
	 * Fills `helperHolds`: each call of a multi-lock helper of `takes` opens a hold of each lock the helper takes, which
	 * the caller's own gives of it, and its calls of a helper giving it back, close.
	 */
	private function collectHelperHolds(
		takes: Array<LockCall>, gives: Array<LockCall>, pairIds: Array<String>, unresolved: Array<String>
	): Void {
		final walker: Null<LockWindow> = _walker;
		if (walker == null) return;
		final opened: Array<{ call: CallEdge, op: LockCall }> = [];
		final closed: Array<{ call: CallEdge, op: LockCall }> = [];
		for (id => list in opsByFunction(takes, gives)) if (list.length > 1 && mayWrap(id, pairIds, unresolved)) {
			final fn: Null<QueryNode> = _trees.ofEdge(list[0].call.edge);
			if (fn == null) continue;
			final opens: Bool = list.foreach(o -> o.takes);
			if (!list.foreach(o -> o.takes == opens && onEveryPath(walker, fn, o.call, opens))) continue;
			for (call in _graph.inEdges(id))
				if (call.kind == Call)
					for (o in list) (opens ? opened : closed).push({ call: call, op: o.call });
		}
		for (o in opened) {
			final lock: Null<String> = lockOf(o.op.edge);
			final releases: Array<Int> = releasesOf(o.call, o.op.pair, lock, gives).concat([
				for (c in closed) {
					final at: Null<Span> = c.call.span;
					if (at != null && c.call.from == o.call.from && c.call.file == o.call.file && lockOf(c.op.edge) == lock) at.from;
				}
			]);
			helperHolds.push(hold(o.call, o.op.pair, lock, releases));
		}
	}

	/** Whether `call` works a named lock on every path of `fn`: in, for a take; out, for a give. */
	private function onEveryPath(walker: LockWindow, fn: QueryNode, call: LockCall, takes: Bool): Bool {
		final at: Null<Span> = call.edge.span;
		if (at == null || lockOf(call.edge) == null) return false;
		return takes ? walker.runsOnEveryPath(fn, at.from) : walker.releasesOnEveryPath(fn, [at.from]);
	}

	/**
	 * The lock wrappers of the graph (`_wrappers`, `_siteLocks`) and their calls, grown a nesting level a round: a round
	 * reads the calls of the last round's wrappers as takes and gives, finds the functions whose whole lock traffic is
	 * one of them (`wrapperOf`), and keeps those every call of which it sees (`dropUncovered`). Empty when the rounds do
	 * not settle — every wrapper's own take then leaks as it did.
	 */
	private function inferWrappers(
		takes: Array<LockCall>, gives: Array<LockCall>, pairIds: Array<String>, unresolved: Array<String>
	): Array<{ call: LockCall, wrapper: LockWrapper }> {
		var wrappers: Map<String, LockWrapper> = [];
		for (_ in 0...WRAPPER_ROUNDS) {
			final sites: Map<String, { call: LockCall, wrapper: LockWrapper }> = wrapperSites(wrappers);
			_siteLocks.clear();
			_siteSelf.clear();
			for (key => site in sites) {
				_siteLocks[key] = site.wrapper.lock;
				_siteSelf[key] = site.wrapper.self;
			}
			final ops: Map<String, Array<{ call: LockCall, takes: Bool }>> = opsByFunction(
				takes.concat([for (site in sites) if (site.wrapper.takes) site.call]),
				gives.concat([for (site in sites) if (!site.wrapper.takes) site.call])
			);
			final next: Map<String, LockWrapper> = [];
			for (id => list in ops) if (list.length == 1 && mayWrap(id, pairIds, unresolved)) {
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
		final fn: Null<QueryNode> = _trees.ofEdge(call.edge);
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

	public static inline function memberName(field: String): String {
		return field.substr(field.lastIndexOf('.') + 1);
	}

	/** The lock calls of `takes` (takes) and `gives` (gives), grouped by the function each sits in. */
	private static function opsByFunction(
		takes: Array<LockCall>, gives: Array<LockCall>
	): Map<String, Array<{ call: LockCall, takes: Bool }>> {
		final ops: Map<String, Array<{ call: LockCall, takes: Bool }>> = [];
		for (list in [takes, gives]) for (c in list) {
			final known: Array<{ call: LockCall, takes: Bool }> = ops[c.edge.from] ?? [];
			known.push({ call: c, takes: list == takes });
			ops[c.edge.from] = known;
		}
		return ops;
	}

	private static inline function sameWrapper(a: Null<LockWrapper>, b: LockWrapper): Bool {
		return a != null && a.takes == b.takes && a.lock == b.lock && a.pair == b.pair && a.self == b.self;
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

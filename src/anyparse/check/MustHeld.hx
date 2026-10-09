package anyparse.check;

import anyparse.check.LockSites.LockAcquire;
import anyparse.check.LockSites.LockGive;
import anyparse.query.CallGraph;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * The locks a thread certainly holds at a point of a function, under a valuation of its tracked parameters
 * (`EdgeConditions`), each on the object it is held on: `static`, `this`, or the object a path of stable fields read off
 * `this` names (`ObjectPaths`).
 *
 * They are the function's own takes that run on every path to the point — the deepest node holding both a statement
 * sequence whose statement holding the take comes first, reached through statement sequences and `if`s the valuation
 * decides — with nothing giving the lock back on the way, plus the locks every call into the function holds on its way
 * in (the meet over its callers, carried onto the callee's `this` when the callee runs on the caller's object or on the
 * object a path of stable fields of it names), kept while nothing on the way may give them back. A point may give a lock back
 * by a give of it that does not leave the function first, a call into a function giving it back without taking it, or —
 * when code an unresolved call may run can do that — an unresolved call. A function a callback registration, an unresolved
 * call or the walk's own assumption enters holds nothing on entry, and so does one code outside the run may call — any
 * function, unless its chain declares `closedWorld` and nothing outside can invoke it — or one the meet does not settle.
 *
 * A lock no member names is never a sealed member's object, so its gives give none of these back. Positive on every
 * count: anything unplaced holds nothing.
 */
@:nullSafety(Strict)
final class MustHeld {

	/** The object of a static lock: one however it is reached. */
	public static inline final STATIC_OBJECT: String = 'static';

	/** The object of a lock of the object the function runs on. */
	public static inline final SELF_OBJECT: String = 'this';

	/** Joins a must-held lock and the object it is held on. */
	private static inline final ON: String = '@';

	/** Bound on the meets of each state, on average: past it every entry is taken to hold nothing (`unsettled`). */
	private static inline final PASSES: Int = 64;

	/** Whether the meet over the callers did not settle within its bound, so every entry holds nothing. */
	public var unsettled(default, null): Bool = false;

	private final _graph: CallGraph;
	private final _sites: LockSites;
	private final _states: ThreadStates;
	private final _conditions: EdgeConditions;
	private final _repetition: CallRepetition;
	private final _trees: FunctionTrees;
	private final _shape: RefShape;

	/** The holds of named locks each function takes itself, a helper's own takes left to its callers. */
	private final _holdsIn: Map<String, Array<LockAcquire>> = [];

	/** The gives of each function. */
	private final _givesIn: Map<String, Array<LockGive>> = [];

	/** `<id>|<valuation>` -> the locks held on entry, `<lock>@<object>`. */
	private final _entry: Map<String, Array<String>> = [];

	/** `<id>|<valuation>|<offset>|<cover>` -> the own takes must-held there. */
	private final _own: Map<String, Array<String>> = [];

	private final _sequenceKinds: Array<String>;
	private final _blockKinds: Array<String>;
	private final _tryKinds: Array<String>;
	private final _ifKinds: Array<String>;

	/** What may give a lock back on the way to a point. */
	private final _releasers: LockReleasers;

	/** The objects calls are made on, relative to the running object. */
	private final _paths: ObjectPaths;

	/** What the bodies of the functions say: conditions, runs of a valuation, locals locks are taken on. */
	private final _body: BodyFacts;

	public function new(
		graph: CallGraph, plugin: GrammarPlugin, trees: FunctionTrees, sites: LockSites, states: ThreadStates, conditions: EdgeConditions,
		repetition: CallRepetition, holds: Array<LockAcquire>, inertRef: (CallEdge) -> Bool, unresolvedNames: Array<String>,
		seedable: (String) -> Bool
	) {
		_graph = graph;
		_sites = sites;
		_states = states;
		_conditions = conditions;
		_repetition = repetition;
		_trees = trees;
		_shape = plugin.refShape();
		_paths = new ObjectPaths(graph, plugin, sites);

		final flow: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		_blockKinds = flow == null ? [] : flow.blockKinds();
		_tryKinds = (_shape.tryStatementKinds ?? []).concat(_shape.tryExpressionKinds ?? []);
		_body = new BodyFacts(sites, trees, new ArgumentValues(graph, trees, plugin), _shape, _tryKinds);
		_sequenceKinds = _blockKinds.concat(_shape.exprStatementKind == null ? [] : [_shape.exprStatementKind])
			.concat(_shape.expressionBodyKinds ?? [])
			.concat(_shape.localDeclKinds ?? [])
			.concat(_shape.parenKind == null ? [] : [_shape.parenKind]);
		_ifKinds = (_shape.ifStatementKinds ?? []).concat(_shape.ifExpressionKinds ?? []);
		for (a in holds) if (a.lock != null && !sites.helpers.contains(a.edge.from)) {
			final list: Array<LockAcquire> = _holdsIn[a.edge.from] ?? [];
			list.push(a);
			_holdsIn[a.edge.from] = list;
		}
		for (g in sites.gives) {
			final list: Array<LockGive> = _givesIn[g.edge.from] ?? [];
			list.push(g);
			_givesIn[g.edge.from] = list;
		}
		_releasers = new LockReleasers(graph, plugin, trees, sites, states, conditions, holds, inertRef, unresolvedNames, {
			sameObject: sameObject,
			takenBefore: runsBefore,
			runs: _body.runsOf
		});
		solveEntries(inertRef, unresolvedNames, seedable);
	}

	/**
	 * The locks must-held at the offset `at` of `id`'s body (in `file`) under `valuation`, as `<lock>@<object>` (`lockOf`,
	 * `objectOf`). With `cover`, a give on the way that `cover` was given back before on every path, and is not taken
	 * again after, does not count: a hold of `cover` reaching `at` never passed it.
	 */
	public function at(id: String, valuation: String, file: String, at: Int, ?cover: String): Array<String> {
		final out: Array<String> = [
			for (h in _entry['$id|$valuation'] ?? []) if (!givenBack(id, valuation, file, lockOf(h), -1, at, cover)) h
		];
		for (h in ownAt(id, valuation, file, at, cover)) if (!out.contains(h)) out.push(h);
		return out;
	}

	/** The object the hold `a` takes its lock on, relative to its function; null when no path of stable fields names it. */
	public function holdObject(a: LockAcquire): Null<String> {
		final inner: Null<CallEdge> = a.inner;
		return inner == null ? takeObject(a.edge) : carried(takeObject(inner), a.edge);
	}

	/**
	 * The object the take `edge` works the lock of, relative to the function it sits in: `static` for a static lock,
	 * `this` for the running object's (`LockSites.selfTake`), the path of stable fields of the running object a wrapper
	 * call is made on (`ObjectPaths`), for a wrapper working the lock of its receiver; null when no such path names it.
	 */
	public function takeObject(edge: CallEdge): Null<String> {
		final lock: Null<String> = _sites.lockOf(edge);
		if (lock == null) return null;
		if (_sites.selfTake(edge)) return _sites.isStaticLock(lock) ? STATIC_OBJECT : SELF_OBJECT;
		return _sites.worksReceiverLock(edge) ? _paths.receiverPath(edge) : null;
	}

	/**
	 * Whether the take of the hold `a` and the give `g` in one function work the lock of one object: the object a path
	 * names (`holdObject`; a helper's give carried as its take is) when either has one, else both made
	 * on the same parameter or local, or the same member read off one, which the function declares once
	 * and writes nowhere (`h.b.acquire(); … h.b.release();`, `db.batchLock(); … db.batchUnlock();`).
	 */
	public function sameObject(a: LockAcquire, g: LockGive): Bool {
		final inner: Null<CallEdge> = g.inner;
		final held: Null<String> = holdObject(a);
		final given: Null<String> = inner == null ? takeObject(g.edge) : carried(takeObject(inner), g.edge);
		if (held != null || given != null) return held != null && held == given;
		if (a.inner != null || inner != null || a.edge.from != g.edge.from) return false;
		final root: Null<String> = _body.localRoot(a.edge);
		return root != null && root == _body.localRoot(g.edge);
	}

	/** A must-held entry (`at`): `lock` held on `object`. */
	public static inline function heldOn(lock: String, object: String): String {
		return lock + ON + object;
	}

	/**
	 * Whether running `id` may give `lock` back without having taken it: it or a function it calls does (`LockReleasers`),
	 * or code an unresolved call of it may run can.
	 */
	public function mayRelease(lock: String, id: String): Bool {
		if (_releasers.releasersOf(lock).exists(id)) return true;
		return _releasers.hazard(lock) && (_releasers.blindIn(id) ?? [0]).length > 0;
	}

	/** The lock of a must-held entry (`at`). */
	public static inline function lockOf(held: String): String {
		return held.substring(0, held.lastIndexOf(ON));
	}

	/** The object of a must-held entry (`at`). */
	public static inline function objectOf(held: String): String {
		return held.substring(held.lastIndexOf(ON) + 1);
	}

	/** What a lock held on `object` in the caller is held on in the callee of `call`; null when nothing says. */
	public function carried(object: Null<String>, call: CallEdge): Null<String> {
		if (object == null || object == STATIC_OBJECT) return object;
		final self: Bool = _sites.selfCall(call);
		if (object == SELF_OBJECT) return self ? object : null;
		final path: Null<String> = _paths.receiverPath(call);
		return if (path == object)
			SELF_OBJECT
		else if (path != null && object.startsWith(path + ObjectPaths.SEPARATOR))
			object.substring(path.length + ObjectPaths.SEPARATOR.length)
		else if (self)
			object
		else
			null;
	}

	/** The own takes of `id` must-held at `at` under `valuation`: each run on every path there, with no give since. */
	private function ownAt(id: String, valuation: String, file: String, at: Int, cover: Null<String>): Array<String> {
		final key: String = '$id|$valuation|$at|${cover ?? ''}';
		final known: Null<Array<String>> = _own[key];
		if (known != null) return known;
		final out: Array<String> = [];
		for (a in _holdsIn[id] ?? []) {
			final lock: Null<String> = a.lock;
			final object: Null<String> = holdObject(a);
			final end: Int = a.edge.span?.to ?? at + 1;
			if (lock == null || object == null || end > at) continue;
			if (!runsBefore(a.edge, valuation, at) || givenBack(id, valuation, file, lock, end, at, cover)) continue;
			final held: String = lock + ON + object;
			if (!out.contains(held)) out.push(held);
		}
		_own[key] = out;
		return out;
	}

	/**
	 * Whether something of `id`'s body that runs under `valuation` after `from` and before `at` — or in a loop around
	 * `at` past `from` — may give `lock` back (`givePoints`), unless `cover` was given back on every path to it already and
	 * is not taken again before `at` (`coveredAt`).
	 */
	private function givenBack(id: String, valuation: String, file: String, lock: String, from: Int, at: Int, cover: Null<String>): Bool {
		final found: Null<Array<Span>> = _repetition.loopsAt(file, at);
		final points: Null<Array<Int>> = givePoints(id, valuation, lock, at);
		if (found == null || points == null) return true;
		final loops: Array<Span> = found;
		final covered: String = cover ?? '';
		return points.exists(
			pos ->
				pos > from && (pos < at || loops.exists(l -> l.from > from && l.from <= pos && pos < l.to))
				&& (covered == '' || !coveredAt(id, valuation, file, covered, pos, at))
		);
	}

	/**
	 * The starts of what in `id`'s body may give `lock` back under `valuation`: its gives of it that run and do not leave
	 * the function before `at` first, its calls into a function giving it back without taking it, the values it hands on
	 * to run that may (`U.now(() -> m.release())`), and — when code an unresolved call may run can give it back — its
	 * unresolved calls; null when that code is anywhere in it.
	 */
	private function givePoints(id: String, valuation: String, lock: String, at: Int): Null<Array<Int>> {
		final points: Array<Int> = [
			for (g in _givesIn[id] ?? []) if (g.lock == lock && runs(id, valuation, g.edge) && !leavesFirst(g.edge, at))
				g.edge.span?.from ?? -1
		];
		final releasers: Map<String, Bool> = _releasers.releasersOf(lock);
		for (e in _graph.outEdges(id)) if (_releasers.runsFrom(e) && releasers.exists(e.to) && runs(id, valuation, e))
			points.push(e.span?.from ?? -1);
		if (!_releasers.hazard(lock)) return points;
		final blind: Null<Array<Int>> = _releasers.blindIn(id);
		return blind == null ? null : points.concat(blind);
	}

	/** Whether `edge` of `id`'s body runs under `valuation` on some thread a state of `id` runs on. */
	private function runs(id: String, valuation: String, edge: CallEdge): Bool {
		return _states.statesOf(id).exists(s -> s.valuation == valuation && _conditions.carried(edge, valuation, s.ctx) != 0);
	}

	/**
	 * Whether `id`'s body under `valuation` gives `cover` back on every path to the offset `pos` — a give of it that runs
	 * on every path there (`runsBefore`) — and takes it by no call after that give and before `at`, nor in a loop around
	 * `pos`, whose next round may take it again before `at` (none known: not covered).
	 */
	private function coveredAt(id: String, valuation: String, file: String, cover: String, pos: Int, at: Int): Bool {
		final loops: Null<Array<Span>> = _repetition.loopsAt(file, pos);
		if (loops == null) return false;
		final around: Array<Span> = loops;
		return (_givesIn[id] ?? []).exists(g -> {
			final given: Int = g.edge.span?.to ?? pos + 1;
			g.lock == cover && given <= pos && runs(id, valuation, g.edge) && runsBefore(g.edge, valuation, pos)
			&& !(_holdsIn[id] ?? []).exists(a -> {
				final take: Int = a.edge.span?.from ?? -1;
				a.lock == cover && (take > given && take < at || around.exists(l -> l.from <= take && take < l.to));
			});
		});
	}

	/**
	 * Whether the take `take` runs on every path to the offset `at` after it in its function under `valuation`: the
	 * deepest node holding both is a statement sequence, whose statement holding the take comes first (`towardTake`) and
	 * leads to it (`leadsTo`).
	 */
	private function runsBefore(take: CallEdge, valuation: String, at: Int): Bool {
		final site: Null<Span> = take.span;
		final first: Null<QueryNode> = site == null ? null : towardTake(take.file, site, at);
		return site != null && first != null && leadsTo(first, site, take.from, valuation);
	}

	/**
	 * The child holding `site` of the deepest node of `file`'s tree holding both `site` and the offset `at` after it,
	 * when that node is a statement sequence; null otherwise.
	 */
	private function towardTake(file: String, site: Span, at: Int): Null<QueryNode> {
		var common: Null<QueryNode> = _trees.ofFile(file);
		while (common != null) {
			final cT: Null<QueryNode> = common.children.find(c -> c.span != null && c.span.from <= site.from && c.span.to >= site.to);
			final cA: Null<QueryNode> = common.children.find(c -> c.span != null && c.span.from <= at && at < c.span.to);
			if (cT == null || cA == null) return null;
			if (cT != cA) return _sequenceKinds.contains(common.kind) ? cT : null;
			common = cT;
		}
		return null;
	}

	/**
	 * Whether `node` reaches the call at `site` through statement sequences, and `if`s whose condition `valuation` decides
	 * for the branch holding it, in the body of `id`.
	 */
	private function leadsTo(node: QueryNode, site: Span, id: String, valuation: String): Bool {
		var cursor: QueryNode = node;
		while (true) {
			if (cursor.kind == _shape.callKind && cursor.span?.from == site.from && cursor.span?.to == site.to) return true;
			final child: Null<QueryNode> = cursor.children.find(c -> c.span != null && c.span.from <= site.from && c.span.to >= site.to);
			if (child == null) return false;
			if (!_sequenceKinds.contains(cursor.kind)) {
				final branch: Int = cursor.children.indexOf(child);
				if (!_ifKinds.contains(cursor.kind) || branch < 1 || branch > 2) return false;
				if (_body.decided(cursor.children[0], id, valuation) != (branch == 1)) return false;
			}
			cursor = child;
		}
	}

	/**
	 * The locks each state holds on entry: the meet, over every call that runs into it, of what the caller must-holds at
	 * the call, carried onto the callee's objects — nothing for a state something unknown may enter:
	 * a callback registration, an unresolved call, the walk's assumption, or code outside the run
	 * (`seedable`: any function, unless its chain declares `closedWorld` and nothing outside can invoke it).
	 */
	private function solveEntries(inertRef: (CallEdge) -> Bool, unresolvedNames: Array<String>, seedable: (String) -> Bool): Void {
		final keys: Array<{ id: String, valuation: String }> = [];
		final keysOf: Map<String, Array<Int>> = [];
		for (id => node in _graph.nodes) {
			final unknown: Bool = enteredUnknown(id, node, inertRef, unresolvedNames, seedable);
			for (s in _states.statesOf(id)) if (unknown)
				_entry['$id|${s.valuation}'] = []
			else {
				keysOf[id] = (keysOf[id] ?? []).concat([keys.length]);
				keys.push({ id: id, valuation: s.valuation });
			}
		}
		// a worklist: a state is met again only when a caller's entry moved
		final queue: Array<Int> = [for (i in 0...keys.length) i];
		final queued: Array<Bool> = [for (_ in keys) true];
		final bound: Int = keys.length * PASSES;
		var qi: Int = 0;
		while (qi < queue.length) {
			if (qi >= bound) {
				// a state still moving after the bound holds nothing it can prove
				unsettled = true;
				for (k in keys) _entry['${k.id}|${k.valuation}'] = [];
				return;
			}
			final i: Int = queue[qi++];
			queued[i] = false;
			final k: { id: String, valuation: String } = keys[i];
			final next: Null<Array<String>> = meetInto(k.id, k.valuation);
			final key: String = '${k.id}|${k.valuation}';
			if (next == null || _entry.exists(key) && (_entry[key] ?? []).join('\n') == next.join('\n')) continue;
			_entry[key] = next;
			for (e in _graph.outEdges(k.id)) if (e.kind.isInvocation()) for (j in keysOf[e.to] ?? []) if (!queued[j]) {
				queued[j] = true;
				queue.push(j);
			}
		}
	}

	/**
	 * Whether something the meet cannot see may enter `id` (`node`): the walk's assumption, no call into it, a call of its
	 * name the graph resolved to nothing, its value handed on to run, or code outside the run (`seedable`) — whose callers
	 * the meet over those in the run does not include.
	 */
	private function enteredUnknown(
		id: String, node: FnNode, inertRef: (CallEdge) -> Bool, unresolvedNames: Array<String>, seedable: (String) -> Bool
	): Bool {
		return _states.assumed.exists(id) || !_graph.inEdges(id).exists(e -> e.kind.isInvocation())
			|| unresolvedNames.contains(node.name ?? '') || _graph.inEdges(id).exists(e -> e.kind == Ref && !inertRef(e)) || seedable(id);
	}

	/** The meet over the solved callers of the state `id` under `valuation`, sorted; null while none is solved. */
	private function meetInto(id: String, valuation: String): Null<Array<String>> {
		var meet: Null<Array<String>> = null;
		for (call in _graph.inEdges(id)) if (call.kind.isInvocation()) for (s in _states.statesOf(call.from)) {
			final at: Null<Span> = call.span;
			if (_conditions.carried(call, s.valuation, s.ctx) == 0 || _conditions.bind(call, s.valuation) != valuation) continue;
			if (!_entry.exists('${call.from}|${s.valuation}')) continue;
			final held: Array<String> = [];
			if (at != null) for (h in this.at(call.from, s.valuation, call.file, at.from)) {
				final object: Null<String> = carried(objectOf(h), call);
				if (object != null) held.push(lockOf(h) + ON + object);
			}
			final known: Null<Array<String>> = meet;
			meet = known == null ? held : known.filter(h -> held.contains(h));
		}
		meet?.sort(Reflect.compare);
		return meet;
	}

	/**
	 * Whether every path from the give `give` leaves the function before it reaches the offset `at`: the block it sits in
	 * (`blockOf`) holds no `at` and ends in a `return` or a `throw` after it — `if (done) { m.release(); return; }`. A
	 * `throw` inside a `try`'s body leaves nothing: a `catch` of it may go on to `at`.
	 */
	private function leavesFirst(give: CallEdge, at: Int): Bool {
		final site: Null<Span> = give.span;
		final block: Null<QueryNode> = site == null ? null : blockOf(give.file, site, at);
		if (site == null || block == null) return false;
		final span: Null<Span> = block.span;
		if (span == null || span.from <= at && at < span.to || block.children.length == 0) return false;
		final returns: Array<String> = [for (k in [_shape.returnStatementKind, _shape.voidReturnKind]) if (k != null) k];
		final last: QueryNode = block.children[block.children.length - 1];
		if ((last.span?.from ?? -1) <= site.from) return false;
		return returns.contains(last.kind) || (_shape.throwKinds ?? []).contains(last.kind) && !_body.inTryBody(give.file, site);
	}

	/**
	 * The innermost block of `file`'s tree around `site`; null when there is none, or when a `try` around it holds `at`
	 * in a `catch` — a call between the give and the exit may throw into it.
	 */
	private function blockOf(file: String, site: Span, at: Int): Null<QueryNode> {
		var block: Null<QueryNode> = null;
		var node: Null<QueryNode> = _trees.ofFile(file);
		while (node != null) {
			final child: Null<QueryNode> = node.children.find(c -> c.span != null && c.span.from <= site.from && c.span.to >= site.to);
			if (child == null) return block;
			final around: Null<Span> = child.span;
			final body: Null<Span> = child.children.length > 0 ? child.children[0].span : null;
			final inBody: Bool = body != null && body.from <= at && at < body.to;
			if (_tryKinds.contains(child.kind) && around != null && around.from <= at && at < around.to && !inBody) return null;
			if (_blockKinds.contains(child.kind)) block = child;
			node = child;
		}
		return block;
	}

	/**
	 * Whether some function may give `lock` back without having taken it (`LockReleasers`): a thread holding it may then
	 * lose it to another while its own window still runs, so its holds exclude no one for sure.
	 */
	public function releasedUntaken(lock: String): Bool {
		return _releasers.releasersOf(lock).keys().hasNext();
	}

}

/**
 * What `MustHeld` reads off one function's body: what a condition evaluates to under a valuation of its tracked
 * parameters, every run a valuation may stand for, the local a lock call is made on, and whether a `try` may stop an
 * exception thrown at a site.
 */
@:nullSafety(Strict)
private final class BodyFacts {

	/** The most parameters a valuation does not know that `runsOf` reads as each value they may hold. */
	private static inline final KNOWN_UNKNOWNS: Int = 3;

	private final _sites: LockSites;
	private final _trees: FunctionTrees;
	private final _values: ArgumentValues;
	private final _shape: RefShape;
	private final _tryKinds: Array<String>;

	public function new(
		sites: LockSites, trees: FunctionTrees, values: ArgumentValues, shape: RefShape, tryKinds: Array<String>
	) {
		_sites = sites;
		_trees = trees;
		_values = values;
		_shape = shape;
		_tryKinds = tryKinds;
	}

	/** What `cond` evaluates to under `valuation` of `id`'s tracked parameters; null when any part of it is undecided. */
	public function decided(cond: QueryNode, id: String, valuation: String): Null<Bool> {
		final kids: Array<QueryNode> = cond.children;
		final kind: String = cond.kind;
		if (kind == _shape.parenKind && kids.length == 1) return decided(kids[0], id, valuation);
		if (kind == _shape.notKind && kids.length == 1) {
			final inner: Null<Bool> = decided(kids[0], id, valuation);
			return inner == null ? null : !inner;
		}
		if ((kind == _shape.logicalAndKind || kind == _shape.logicalOrKind) && kids.length == 2) {
			final a: Null<Bool> = decided(kids[0], id, valuation);
			final b: Null<Bool> = decided(kids[1], id, valuation);
			final and: Bool = kind == _shape.logicalAndKind;
			// either side settling the operator settles it; else both sides must be known
			return if (a == !and || b == !and)
				!and
			else if (a != null && b != null)
				and
			else
				null;
		}
		return decidedParam(cond, id, valuation);
	}

	/**
	 * Every run of `id` its `valuation` may stand for, each deciding at least as much: a tracked parameter it does not
	 * know, or knows only to be never null, read as true and as false — a bare condition reads a `Bool` — and, when some
	 * comparison of the body tests it against `null`, as `null` too. A tracked parameter is never written, so a run gives
	 * it one value throughout. Past `KNOWN_UNKNOWNS` such parameters, `valuation` itself.
	 */
	public function runsOf(id: String, valuation: String): Array<String> {
		final nullTested: Array<String> = nullTestedIn(id);
		final tracked: Array<String> = _values.tracked(id);
		var runs: Array<String> = [''];
		var open: Int = 0;
		for (i in 0...valuation.length) {
			final c: String = valuation.charAt(i);
			final values: Array<String> = if (c == ArgumentValues.UNKNOWN)
				[ArgumentValues.TRUE, ArgumentValues.FALSE].concat(
					i < tracked.length && nullTested.contains(tracked[i]) ? [ArgumentValues.NULL] : []
				)
			else if (c == ArgumentValues.NON_NULL)
				[ArgumentValues.TRUE, ArgumentValues.FALSE]
			else
				[c];
			if (values.length > 1 && ++open > KNOWN_UNKNOWNS) return [valuation];
			runs = [for (r in runs) for (v in values) r + v];
		}
		return runs;
	}

	/**
	 * What the lock call `edge` is made on when it is a name its function declares once and never writes (a lock
	 * wrapper's call, `db.batchLock()`) or a member read off one (`h.b.acquire()`): `<root>` or `<root>.<member>`; null
	 * for any other receiver.
	 */
	public function localRoot(edge: CallEdge): Null<String> {
		final callee: Null<QueryNode> = _sites.calleeOf(edge);
		if (callee == null || !_sites.isAccess(callee.kind) || callee.children.length == 0) return null;
		final receiver: QueryNode = callee.children[0];
		final member: Null<String> = _sites.isAccess(receiver.kind) ? receiver.name : null;
		final root: Null<QueryNode> = member == null ? receiver : receiver.children.length > 0 ? receiver.children[0] : null;
		final name: Null<String> = root?.name;
		final fn: Null<QueryNode> = _trees.ofId(edge.from);
		if (root == null || root.kind != _shape.identKind || name == null || name == _shape.selfReferenceText || fn == null) return null;
		final declared: Array<QueryNode> = [];
		_values.collectNamed(fn, name, declared);
		return declared.length == 1 && !writes(fn, name) ? member == null ? name : '$name.$member' : null;
	}

	/** Whether `site` of `file` sits in the body of a `try`, whose `catch` an exception thrown there may land in. */
	public function inTryBody(file: String, site: Span): Bool {
		var node: Null<QueryNode> = _trees.ofFile(file);
		while (node != null) {
			final child: Null<QueryNode> = node.children.find(c -> c.span != null && c.span.from <= site.from && c.span.to >= site.to);
			if (child == null) return false;
			final body: Null<Span> = child.children.length > 0 ? child.children[0].span : null;
			if (_tryKinds.contains(child.kind) && body != null && body.from <= site.from && site.to <= body.to) return true;
			node = child;
		}
		return false;
	}

	/** What a tracked parameter of `id` read bare, or tested against `null`, as `cond` evaluates to under `valuation`. */
	private function decidedParam(cond: QueryNode, id: String, valuation: String): Null<Bool> {
		final tracked: Array<String> = _values.tracked(id);
		final kind: String = cond.kind;
		final nullTest: Bool = (kind == _shape.eqKind || kind == _shape.notEqKind) && cond.children.length == 2;
		final read: Null<QueryNode> = kind == _shape.identKind ? cond : nullTest ? _values.nullTested(cond) : null;
		final at: Int = read != null && read.kind == _shape.identKind ? tracked.indexOf(read.name ?? '') : -1;
		final value: String = at < 0 ? ArgumentValues.UNKNOWN : valuation.charAt(at);
		if (!nullTest) return switch value {
			case ArgumentValues.TRUE: true;
			case ArgumentValues.FALSE: false;
			case _: null;
		};
		final isNull: Null<Bool> = switch value {
			case ArgumentValues.NULL: true;
			case ArgumentValues.NON_NULL: false;
			case _: null;
		};
		return isNull == null ? null : isNull == (kind == _shape.eqKind);
	}

	/** The names some comparison of `id`'s body tests against `null` (`ArgumentValues.nullTested`). */
	private function nullTestedIn(id: String): Array<String> {
		final fn: Null<QueryNode> = _trees.ofId(id);
		final out: Array<String> = [];
		if (fn == null) return out;
		function walk(node: QueryNode): Void {
			if (node.kind == _shape.eqKind || node.kind == _shape.notEqKind) {
				final read: Null<QueryNode> = _values.nullTested(node);
				final name: Null<String> = read?.kind == _shape.identKind ? read?.name : null;
				if (name != null && !out.contains(name)) out.push(name);
			}
			for (c in node.children) walk(c);
		}
		walk(fn);
		return out;
	}

	/** Whether something under `node` writes the bare name `name` (`RefShape.writeParentKinds`). */
	private function writes(node: QueryNode, name: String): Bool {
		final kids: Array<QueryNode> = node.children;
		return _shape.writeParentKinds.contains(node.kind) && kids.length > 0 && kids[0].kind == _shape.identKind && kids[0].name == name
			|| kids.exists(k -> writes(k, name));
	}

}

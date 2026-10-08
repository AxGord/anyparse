package anyparse.check;

import anyparse.check.LockSites.LockAcquire;
import anyparse.query.CallGraph;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.runtime.Span;

using Lambda;

/**
 * The locks a thread certainly holds at a point of a function, under a valuation of its tracked parameters
 * (`EdgeConditions`), each on the object it is held on: `static`, `this`, or the object a `final` field of `this` names.
 *
 * They are the function's own takes that run on every path to the point — the deepest node holding both a statement
 * sequence whose statement holding the take comes first, reached through statement sequences and `if`s the valuation
 * decides — with nothing giving the lock back on the way, plus the locks every call into the function holds on its way
 * in (the meet over its callers, carried onto the callee's `this` when the callee runs on the caller's object or on the
 * object a `final` field of it names), kept while nothing on the way may give them back. A point may give a lock back
 * by a give of it that does not leave the function first, a call into a function giving it back without taking it, or —
 * when code an unresolved call may run can do that — an unresolved call. A function a callback registration, an
 * unresolved call or the walk's own assumption enters holds nothing on entry; so does one the meet does not settle.
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

	/** Bound on the passes of the meet: past it every entry still moving is taken to hold nothing. */
	private static inline final PASSES: Int = 64;

	private final _graph: CallGraph;
	private final _sites: LockSites;
	private final _states: ThreadStates;
	private final _conditions: EdgeConditions;
	private final _repetition: CallRepetition;
	private final _trees: FunctionTrees;
	private final _values: ArgumentValues;
	private final _shape: RefShape;
	private final _holds: Array<LockAcquire>;

	/** The holds of named locks each function takes itself, a helper's own takes left to its callers. */
	private final _holdsIn: Map<String, Array<LockAcquire>> = [];

	/** The gives of each function. */
	private final _givesIn: Map<String, Array<{ edge: CallEdge, lock: Null<String> }>> = [];

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

	public function new(
		graph: CallGraph, plugin: GrammarPlugin, trees: FunctionTrees, sites: LockSites, states: ThreadStates, conditions: EdgeConditions,
		repetition: CallRepetition, holds: Array<LockAcquire>, inertRef: (CallEdge) -> Bool, unresolvedNames: Array<String>
	) {
		_graph = graph;
		_sites = sites;
		_states = states;
		_conditions = conditions;
		_repetition = repetition;
		_trees = trees;
		_shape = plugin.refShape();
		_values = new ArgumentValues(graph, trees, plugin);
		_holds = holds;
		final flow: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		_blockKinds = flow == null ? [] : flow.blockKinds();
		_tryKinds = (_shape.tryStatementKinds ?? []).concat(_shape.tryExpressionKinds ?? []);
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
			final list: Array<{ edge: CallEdge, lock: Null<String> }> = _givesIn[g.edge.from] ?? [];
			list.push(g);
			_givesIn[g.edge.from] = list;
		}
		_releasers = new LockReleasers(graph, plugin, trees, sites, states, conditions, holds, inertRef, unresolvedNames);
		solveEntries(inertRef, unresolvedNames);
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

	/** The object the hold `a` takes its lock on, relative to its function; null when no `final` member names it. */
	public function holdObject(a: LockAcquire): Null<String> {
		final inner: Null<CallEdge> = a.inner;
		return inner == null ? takeObject(a.edge) : carried(takeObject(inner), a.edge);
	}

	/**
	 * The object the take `edge` works the lock of, relative to the function it sits in: `static` for a static lock,
	 * `this` for the running object's (`LockSites.selfTake`), the `final` member of the running object a wrapper call is
	 * made on, for a wrapper working the lock of its receiver; null when no such member names that object.
	 */
	public function takeObject(edge: CallEdge): Null<String> {
		final lock: Null<String> = _sites.lockOf(edge);
		if (lock == null) return null;
		if (_sites.selfTake(edge)) return _sites.isStaticLock(lock) ? STATIC_OBJECT : SELF_OBJECT;
		return _sites.worksReceiverLock(edge) ? finalField(ownFieldReceiver(edge)) : null;
	}

	/** The lock of a must-held entry (`at`). */
	public static inline function lockOf(held: String): String {
		return held.substring(0, held.lastIndexOf(ON));
	}

	/** The object of a must-held entry (`at`). */
	public static inline function objectOf(held: String): String {
		return held.substring(held.lastIndexOf(ON) + 1);
	}

	/** `field` itself when it names a `final` field: one whose object no write changes under a hold; null otherwise. */
	private function finalField(field: Null<String>): Null<String> {
		final dot: Int = field?.lastIndexOf('.') ?? -1;
		if (field == null || dot <= 0) return null;
		final info: Null<MemberInfo> = _graph.types.memberOnChain(field.substring(0, dot), field.substring(dot + 1));
		final kind: String = info?.kind ?? '';
		return (_shape.fieldDeclKinds ?? []).contains(kind) && !(_shape.mutableFieldDeclKinds ?? []).contains(kind) ? field : null;
	}

	/** What a lock held on `object` in the caller is held on in the callee of `call`; null when nothing says. */
	private function carried(object: Null<String>, call: CallEdge): Null<String> {
		if (object == null || object == STATIC_OBJECT) return object;
		final self: Bool = _sites.selfCall(call);
		if (object == SELF_OBJECT) return self ? object : null;
		return if (ownFieldReceiver(call) == object)
			SELF_OBJECT
		else if (self)
			object
		else
			null;
	}

	/**
	 * The member of the running object the call `edge` is made on — its receiver a bare field or one read off `this`, as
	 * `CallEdge.receiverField` names it; null for any other receiver, a field of another object's included.
	 */
	private function ownFieldReceiver(edge: CallEdge): Null<String> {
		final callee: Null<QueryNode> = _sites.calleeOf(edge);
		final receiver: Null<QueryNode> = callee != null && _sites.isAccess(callee.kind) && callee.children.length > 0
			? callee.children[0]
			: null;
		return receiver != null && _sites.readsOwnMember(receiver) ? edge.receiverField : null;
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
				&& (covered == '' || !coveredAt(id, valuation, covered, pos, at))
		);
	}

	/**
	 * The starts of what in `id`'s body may give `lock` back under `valuation`: its gives of it that run and do not leave
	 * the function before `at` first, its calls into a function giving it back without taking it, and — when code an
	 * unresolved call may run can give it back — its unresolved calls; null when that code is anywhere in it.
	 */
	private function givePoints(id: String, valuation: String, lock: String, at: Int): Null<Array<Int>> {
		final points: Array<Int> = [
			for (g in _givesIn[id] ?? []) if (g.lock == lock && runs(id, valuation, g.edge) && !leavesFirst(g.edge, at))
				g.edge.span?.from ?? -1
		];
		final releasers: Map<String, Bool> = _releasers.releasersOf(lock);
		for (e in _graph.outEdges(id)) if (e.kind.isInvocation() && releasers.exists(e.to) && runs(id, valuation, e))
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
	 * on every path there (`runsBefore`) — and takes it by no call between `pos` and `at`.
	 */
	private function coveredAt(id: String, valuation: String, cover: String, pos: Int, at: Int): Bool {
		final given: Bool = (_givesIn[id] ?? []).exists(
			g -> g.lock == cover && (g.edge.span?.to ?? pos + 1) <= pos && runs(id, valuation, g.edge) && runsBefore(g.edge, valuation, pos)
		);
		return given
			&& !(_holdsIn[id] ?? []).exists(a -> a.lock == cover && (a.edge.span?.from ?? -1) > pos && (a.edge.span?.from ?? -1) < at);
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
				if (decided(cursor.children[0], id, valuation) != (branch == 1)) return false;
			}
			cursor = child;
		}
	}

	/** What `cond` evaluates to under `valuation` of `id`'s tracked parameters; null when any part of it is undecided. */
	private function decided(cond: QueryNode, id: String, valuation: String): Null<Bool> {
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

	/**
	 * The locks each state holds on entry: the meet, over every call that runs into it, of what the caller must-holds at
	 * the call, carried onto the callee's objects — nothing for a state something unknown may enter.
	 */
	private function solveEntries(inertRef: (CallEdge) -> Bool, unresolvedNames: Array<String>): Void {
		final keys: Array<{ id: String, valuation: String }> = [];
		for (id => node in _graph.nodes) for (s in _states.statesOf(id)) {
			final entered: Bool = _graph.inEdges(id).exists(e -> e.kind.isInvocation());
			final unknown: Bool = _states.assumed.exists(id) || !entered || unresolvedNames.contains(node.name ?? '')
				|| _graph.inEdges(id).exists(e -> e.kind == Ref && !inertRef(e));
			if (unknown)
				_entry['$id|${s.valuation}'] = []
			else
				keys.push({ id: id, valuation: s.valuation });
		}
		var changed: Bool = true;
		var passes: Int = 0;
		while (changed && passes++ < PASSES) {
			changed = false;
			for (k in keys) {
				final next: Null<Array<String>> = meetInto(k.id, k.valuation);
				final key: String = '${k.id}|${k.valuation}';
				if (next == null || (_entry[key] ?? []).join('\n') == next.join('\n') && _entry.exists(key)) continue;
				_entry[key] = next;
				changed = true;
			}
		}
		// a state still moving after the bound holds nothing it can prove; one no solved caller reached holds nothing
		if (changed) for (k in keys) _entry['${k.id}|${k.valuation}'] = [];
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
	 * (`blockOf`) holds no `at` and ends in a `return` or a `throw` after it — `if (done) { m.release(); return; }`.
	 */
	private function leavesFirst(give: CallEdge, at: Int): Bool {
		final site: Null<Span> = give.span;
		final block: Null<QueryNode> = site == null ? null : blockOf(give.file, site, at);
		if (site == null || block == null) return false;
		final span: Null<Span> = block.span;
		if (span == null || span.from <= at && at < span.to || block.children.length == 0) return false;
		final exits: Array<String> = (_shape.throwKinds ?? []).concat([for (k in [_shape.returnStatementKind, _shape.voidReturnKind]) if (
			k != null
		) k]);
		final last: QueryNode = block.children[block.children.length - 1];
		return exits.contains(last.kind) && (last.span?.from ?? -1) > site.from;
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

}

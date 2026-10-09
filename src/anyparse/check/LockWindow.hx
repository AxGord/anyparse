package anyparse.check;

import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using Lambda;

/** What one lock acquisition holds along the paths of the function body it sits in. */
typedef HeldWindow = {

	/** The statements and expressions some path reaches while the lock may still be held. */
	final held: Array<QueryNode>;

	/** Whether some path leaves the body — its end, a `return`, a `throw`, a loop jump — still holding the lock. */
	final leaks: Bool;

	/**
	 * The throws some path reaches while the lock may still be held and no `catch` of the body intercepts: a `throw`, or
	 * a call starting at one of the raising offsets `trace` was handed. Each leaves the function with the lock held.
	 */
	final escapes: Array<QueryNode>;
}

/**
 * The path-aware extent of a lock held inside ONE function body: a may-held walk over the statement structure from the
 * acquire call, where a release call clears the lock on ITS path only — `if (c) { m.release(); return; }` leaves every
 * statement after the `if` inside the window, which a source-order cut at the first release would drop.
 *
 * Over-approximates in the held direction wherever the structure is not modelled: a construct the walk does not know is
 * one opaque step (a release nested in it releases nothing, every call in it counts as held), a loop may run its body
 * zero or more times, a `catch` starts from what its `try` was entered or left holding, or held where something in
 * its body raised, a loop jump counts as leaving the body, and so does a `throw`. An exception a CALL raises is in
 * the model only for the calls the caller names as raising (`raisingFroms`, from `ThrowReach`): any other call may
 * raise one too, and no written path says where. The escapes run the other way, toward reporting less: only a `throw`
 * or a raising call raises, a `catch` of any type stops it, a step holding a release raises nothing, and a construct
 * the walk does not know raises only what sits in it outside a nested function and an intercepted `try` body. A body
 * built from a grammar that names no exit kinds (`RefShape.controlExitKinds`) is not traced at all.
 */
@:nullSafety(Strict)
final class LockWindow {

	private final _sequenceKinds: Array<String>;
	private final _ifKinds: Array<String>;
	private final _loopKinds: Array<String>;
	private final _tryKinds: Array<String>;
	private final _switchKinds: Array<String>;
	private final _branchKinds: Array<String>;
	private final _nestedFnKinds: Array<String>;
	private final _exitKinds: Array<String>;
	private final _throwKinds: Array<String>;
	private final _catchKind: Null<String>;
	private final _regionKind: Null<String>;
	private final _callKind: Null<String>;

	private var _acquireFrom: Int = -1;
	private var _releaseFroms: Array<Int> = [];
	private var _held: Array<QueryNode> = [];
	private var _leaks: Bool = false;

	/** The starts of the calls of the traced body that may raise an exception (`trace`). */
	private var _raisingFroms: Array<Int> = [];

	private var _escapes: Array<QueryNode> = [];

	/** Which catch-all branches no value reaches (`ExhaustiveSwitches`), when the walk is told. */
	private final _exhaustive: Null<ExhaustiveSwitches>;

	/** The branches of a `switch` no value reaches, for the trace under way (`trace`, in the function `fnId`). */
	private var _deadBranch: Null<(QueryNode, QueryNode) -> Bool> = null;

	/** How many `try` bodies with a `catch` the walk is inside: a throw there is intercepted, never an escape. */
	private var _catchDepth: Int = 0;

	/** Whether something inside the innermost intercepting `try` body threw while the lock may have been held. */
	private var _raisedHeld: Bool = false;

	public function new(shape: RefShape, flow: ControlFlowSupport, ?exhaustive: ExhaustiveSwitches) {
		_exhaustive = exhaustive;
		// an expression body is a sequence of the one expression it holds
		_sequenceKinds = flow.blockKinds()
			.concat(shape.exprStatementKind == null ? [] : [shape.exprStatementKind])
			.concat(shape.expressionBodyKinds ?? []);
		_ifKinds = (shape.ifStatementKinds ?? []).concat(shape.ifExpressionKinds ?? [])
			.concat(shape.ternaryKind == null ? [] : [shape.ternaryKind]);
		// a `while` shares the condition-first slot with an `if`; what is left after the `if` kinds are the loops
		_loopKinds = [for (k in shape.conditionFirstChildKinds ?? []) if (!_ifKinds.contains(k)) k].concat(
			shape.conditionLastChildKinds ?? []
		)
			.concat(shape.forStmtKind == null ? [] : [shape.forStmtKind]);
		_tryKinds = (shape.tryStatementKinds ?? []).concat(shape.tryExpressionKinds ?? []);
		_switchKinds = shape.switchKinds ?? [];
		_branchKinds = [for (k in [shape.caseBranchKind, shape.defaultBranchKind]) if (k != null) k];
		_nestedFnKinds = MemberKinds.nestedFunctionKinds(shape);
		_exitKinds = shape.controlExitKinds ?? [];
		_throwKinds = shape.throwKinds ?? [];
		_catchKind = shape.catchClauseKind;
		_regionKind = shape.conditionalMemberKind;
		_callKind = shape.callKind;
	}

	/**
	 * The window of the acquire call starting at `acquireFrom` in the function node `fn`, which `releaseFroms` (the
	 * starts of the calls releasing the same lock) close on their own path, and the escapes of the calls starting at
	 * `raisingFroms`. Null when the grammar names no exit kinds, so no path out of the body can be recognised: the
	 * caller must then assume the lock is held anywhere.
	 */
	public function trace(
		fn: QueryNode, acquireFrom: Int, releaseFroms: Array<Int>, raisingFroms: Array<Int>, ?fnId: String
	): Null<HeldWindow> {
		if (_exitKinds.length == 0) return null;
		final exhaustive: Null<ExhaustiveSwitches> = _exhaustive;
		_deadBranch = exhaustive == null || fnId == null ? null : deadIn(exhaustive, fnId);
		reset(acquireFrom, releaseFroms, raisingFroms);
		if (sequence(fn.children, false) == true) _leaks = true;
		return { held: _held, leaks: _leaks, escapes: _escapes };
	}

	/** The branches `exhaustive` says no value reaches, in the function `fnId`. */
	private static function deadIn(exhaustive: ExhaustiveSwitches, fnId: String): (QueryNode, QueryNode) -> Bool {
		return (sw, branch) -> exhaustive.dead(fnId, sw, branch);
	}

	/**
	 * Whether every path through the function node `fn` gives back a lock held on entry: one of the calls starting at
	 * `releaseFroms` runs on each way out of the body. False when the grammar names no exit kinds.
	 */
	public function releasesOnEveryPath(fn: QueryNode, releaseFroms: Array<Int>): Bool {
		if (_exitKinds.length == 0) return false;
		reset(-1, releaseFroms, []);
		return sequence(fn.children, true) != true && !_leaks;
	}

	/**
	 * Whether the call starting at `callFrom` runs on every path into the function node `fn`: it is reached through
	 * statement sequences alone, and nothing before it on the way holds a path out of the body.
	 */
	public function runsOnEveryPath(fn: QueryNode, callFrom: Int): Bool {
		var nodes: Array<QueryNode> = fn.children;
		while (true) {
			var inner: Null<QueryNode> = null;
			for (node in nodes) {
				if (contains(node, callFrom)) {
					inner = node;
					break;
				}
				if (_exitKinds.contains(node.kind) || exits(node)) return false;
			}
			if (inner == null) return false;
			if (inner.kind == _callKind && inner.span?.from == callFrom) return true;
			if (!_sequenceKinds.contains(inner.kind)) return false;
			nodes = inner.children;
		}
	}

	/** The may-held state after `nodes` run in order from `held`; null when no path completes them normally. */
	private function sequence(nodes: Array<QueryNode>, held: Bool): Null<Bool> {
		var state: Null<Bool> = held;
		for (node in nodes) {
			if (state == null) return null;
			state = step(node, state);
		}
		return state;
	}

	/** The may-held state after `node` runs from `held`; null when `node` never completes normally. */
	private function step(node: QueryNode, held: Bool): Null<Bool> {
		// noqa: complexity
		if (!held && !contains(node, _acquireFrom)) return false;
		final kind: String = node.kind;
		final kids: Array<QueryNode> = node.children;
		if (_nestedFnKinds.contains(kind)) return opaque(node, held);
		if (_sequenceKinds.contains(kind)) return sequence(kids, held);
		if (_exitKinds.contains(kind)) {
			final before: Null<Bool> = sequence(kids, held);
			if (before == true) {
				_leaks = true;
				if (_throwKinds.contains(kind)) raise(node);
			}
			return null;
		}
		if (_ifKinds.contains(kind) && kids.length >= 2) {
			final cond: Null<Bool> = step(kids[0], held);
			if (cond == null) return null;
			final otherwise: Null<Bool> = kids.length > 2 ? step(kids[2], cond) : cond;
			return join(step(kids[1], cond), otherwise);
		}
		if (_loopKinds.contains(kind)) {
			// iterate to a fixed point: a lock one pass leaves held is held on the next, from its first statement on
			var entry: Bool = held;
			while (true) {
				final next: Bool = join(entry, sequence(kids, entry)) == true;
				if (next == entry) return entry;
				entry = next;
			}
		}
		if (_tryKinds.contains(kind) && kids.length > 0) {
			final intercepts: Bool = kids.exists(k -> k.kind == _catchKind);
			final outer: Bool = _raisedHeld;
			if (intercepts) {
				_raisedHeld = false;
				_catchDepth++;
			}
			final body: Null<Bool> = step(kids[0], held);
			final raised: Bool = intercepts && _raisedHeld;
			if (intercepts) {
				_catchDepth--;
				_raisedHeld = outer;
			}
			// a catch starts holding what the body was entered or left holding, or held where something in it threw: the
			// exception of a call no `raisingFroms` names is out of the model
			final entry: Bool = held || body == true || raised;
			var out: Null<Bool> = body;
			for (i in 1...kids.length)
				out = join(out, kids[i].kind == _catchKind ? sequence(kids[i].children, entry) : step(kids[i], entry));
			return out;
		}
		if (_switchKinds.contains(kind)) {
			final subject: Null<Bool> = sequence([for (k in kids) if (!_branchKinds.contains(k.kind)) k], held);
			if (subject == null) return null;
			var out: Null<Bool> = subject;
			final dead: Null<(QueryNode, QueryNode) -> Bool> = _deadBranch;
			// a catch-all no value reaches is no path (`ExhaustiveSwitches`)
			for (k in kids) if (_branchKinds.contains(k.kind) && !(dead != null && dead(node, k)))
				out = join(out, sequence(k.children, subject));
			return out;
		}
		// a conditional-compilation region the branch-aware projection split into branches: exactly one of them runs
		if (kind != _regionKind || kids.length <= 0 || !kids.foreach(k -> _sequenceKinds.contains(k.kind))) return opaque(node, held);
		var out: Null<Bool> = held;
		for (k in kids) out = join(out, step(k, held));
		return out;
	}

	/**
	 * One step the walk does not look inside: held throughout when it is entered held or holds the acquire, left held
	 * afterwards unless it IS a release call, and leaking when a path out of the body starts inside it. What raises in
	 * it raises held — after the acquire, when the step holds it — unless a release sits somewhere inside the step too.
	 */
	private function opaque(node: QueryNode, held: Bool): Bool {
		final span: Null<Span> = node.span;
		if (held && node.kind == _callKind && span != null && _releaseFroms.contains(span.from)) return false;
		_held.push(node);
		if (!_nestedFnKinds.contains(node.kind)) {
			if (exits(node)) _leaks = true;
			if (!_releaseFroms.exists(r -> contains(node, r))) raisesInside(node, held ? -1 : _acquireFrom);
		}
		return true;
	}

	/**
	 * Raises every throw and raising call inside the opaque step `node` that starts after `after`, outside a nested
	 * function, outside the body of a `try` with a `catch` (whose catches still run in the step's own context), and
	 * outside a `switch` branch no value reaches.
	 */
	private function raisesInside(node: QueryNode, after: Int): Void {
		final from: Int = node.span?.from ?? -1;
		if (_nestedFnKinds.contains(node.kind)) return;
		if (from > after && (_throwKinds.contains(node.kind) || node.kind == _callKind && _raisingFroms.contains(from))) {
			raise(node);
			if (node.kind != _callKind) return;
		}
		final kids: Array<QueryNode> = node.children;
		final intercepted: Bool = _tryKinds.contains(node.kind) && kids.exists(k -> k.kind == _catchKind);
		final dead: Null<(QueryNode, QueryNode) -> Bool> = _switchKinds.contains(node.kind) ? _deadBranch : null;
		for (i => k in kids) if (!(intercepted && i == 0) && !(dead != null && dead(node, k))) raisesInside(k, after);
	}

	/** A throw reached holding the lock: intercepted inside a `try` with a `catch`, else an escape out of the body. */
	private function raise(node: QueryNode): Void {
		if (_catchDepth > 0)
			_raisedHeld = true;
		else if (!_escapes.contains(node))
			_escapes.push(node);
	}

	private function reset(acquireFrom: Int, releaseFroms: Array<Int>, raisingFroms: Array<Int>): Void {
		_acquireFrom = acquireFrom;
		_releaseFroms = releaseFroms;
		_raisingFroms = raisingFroms;
		_held = [];
		_leaks = false;
		_escapes = [];
		_catchDepth = 0;
		_raisedHeld = false;
	}

	/** Whether `node` holds a path out of the body — an exit statement not inside a nested function. */
	private function exits(node: QueryNode): Bool {
		return node.children.exists(k -> !_nestedFnKinds.contains(k.kind) && (_exitKinds.contains(k.kind) || exits(k)));
	}

	/** The may-held join of two paths; null only when neither completes. */
	private static function join(a: Null<Bool>, b: Null<Bool>): Null<Bool> {
		return a == null && b == null ? null : a == true || b == true;
	}

	/** Whether `offset` falls inside `node`'s span. */
	private static function contains(node: QueryNode, offset: Int): Bool {
		final span: Null<Span> = node.span;
		return span != null && offset >= span.from && offset < span.to;
	}

}

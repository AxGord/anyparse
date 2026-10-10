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

	/**
	 * Whether some path leaves the body — its end, a `return`, a `throw`
	 * no `catch` of the body provably catches — still holding the lock.
	 */
	final leaks: Bool;

	/**
	 * The throws some path reaches while the lock may still be held and no `catch` of the body provably catches: a `throw`, or
	 * a call starting at one of the raising offsets `trace` was handed. Each leaves the function with the lock held.
	 */
	final escapes: Array<QueryNode>;
}

/** A `try` body with a `catch` the walk is inside: its `catch` clauses, and whether a throw held the lock on its way to them. */
private typedef TryFrame = {
	final catches: Array<QueryNode>;
	var raised: Bool;
}

/**
 * The path-aware extent of a lock held inside ONE function body: a may-held walk over the statement structure from the
 * acquire call, where a release call clears the lock on ITS path only — `if (c) { m.release(); return; }` leaves every
 * statement after the `if` inside the window, which a source-order cut at the first release would drop.
 *
 * Over-approximates in the held direction wherever the structure is not modelled: a construct the walk does not know is
 * one opaque step (a release nested in it releases nothing, every call in it counts as held), a loop may run its body
 * zero or more times, a `catch` starts from what its `try` was entered or left holding, or held where something in
 * its body raised, a loop jump goes to the end or the head of its loop, and a `throw` leaves the body unless
 * a `catch` around it provably catches the thrown value (`CatchTypes`). An exception a CALL raises is in
 * the model only for the calls the caller names as raising (`raisingFroms`, from `ThrowReach`): any other call may
 * raise one too, and no written path says where. The escapes run the other way, toward reporting less: only
 * a `throw` or a raising call raises, a `catch` that provably catches it stops it (a raising call's
 * exception is of no known type: a catch-all only), a step holding a release raises nothing, and a construct
 * the walk does not know raises only what sits in it outside a nested function and what no `catch` in it provably catches. A body
 * built from a grammar that names no exit kinds (`RefShape.controlExitKinds`) is not traced at all.
 */
@:nullSafety(Strict)
final class LockWindow {

	private final _sequenceKinds: Array<String>;
	private final _ifKinds: Array<String>;
	private final _loopKinds: Array<String>;
	private final _tryKinds: Array<String>;
	private final _switchKinds: Array<String>;

	/** The local declarations (`var`, `final`), walked as their initializer, and array literals, as their elements in order. */
	private final _declKinds: Array<String>;

	/** The `break` and `continue` statements: a jump to the end or the head of the loop around them, not out of the body. */
	private final _jumpKinds: Array<String>;

	private final _breakKind: Null<String>;
	private final _branchKinds: Array<String>;
	private final _nestedFnKinds: Array<String>;
	private final _exitKinds: Array<String>;
	private final _throwKinds: Array<String>;
	private final _catchKind: Null<String>;
	private final _regionKind: Null<String>;
	private final _callKind: Null<String>;
	private final _shape: RefShape;

	/** Which catch-all branches no value reaches (`ExhaustiveSwitches`), when the walk is told. */
	private final _exhaustive: Null<ExhaustiveSwitches>;

	private var _acquireFrom: Int = -1;
	private var _releaseFroms: Array<Int> = [];
	private var _held: Array<QueryNode> = [];
	private var _leaks: Bool = false;

	/** The starts of the calls of the traced body that may raise an exception (`trace`). */
	private var _raisingFroms: Array<Int> = [];

	private var _escapes: Array<QueryNode> = [];

	/** The value of each fixed flag for the trace under way (`FixedFlags`). */
	private var _decided: Map<String, Bool> = [];

	/** For each loop the walk is inside, innermost last: what its `break`s and its `continue`s leave held. */
	private var _loops: Array<{ brk: Null<Bool>, cont: Null<Bool> }> = [];

	/** The branches of a `switch` no value reaches, for the trace under way (`trace`, in the function `fnId`). */
	private var _deadBranch: Null<(QueryNode, QueryNode) -> Bool> = null;

	/**
	 * The `try` bodies with a `catch` the walk is inside, innermost last: their `catch` clauses, and whether something
	 * thrown in the body while the lock may have been held may reach one of them. A throw goes out of the function
	 * unless one of them provably catches it (`CatchTypes`).
	 */
	private var _tries: Array<TryFrame> = [];

	public function new(shape: RefShape, flow: ControlFlowSupport, ?exhaustive: ExhaustiveSwitches) {
		_shape = shape;
		_exhaustive = exhaustive;
		// an expression body is a sequence of the one expression it holds
		_sequenceKinds = flow.blockKinds()
			.concat(shape.exprStatementKind == null ? [] : [shape.exprStatementKind])
			.concat(shape.expressionBodyKinds ?? []);
		_ifKinds = (shape.ifStatementKinds ?? []).concat(shape.ifExpressionKinds ?? [])
			.concat(shape.ternaryKind == null ? [] : [shape.ternaryKind]);
		_loopKinds = Loops.kindsOf(shape);
		_tryKinds = (shape.tryStatementKinds ?? []).concat(shape.tryExpressionKinds ?? []);
		_switchKinds = shape.switchKinds ?? [];
		_declKinds = inPlaceKindsOf(shape);
		_jumpKinds = [
			for (k in [shape.breakStatementKind, shape.continueStatementKind]) if (k != null) k
		];
		_breakKind = shape.breakStatementKind;
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
		_deadBranch = exhaustive == null || fnId == null ? null : deadIn(exhaustive, fn, fnId);
		// once per value of each fixed flag (`FixedFlags`): every run fixes them, so the traces' union covers every run
		final flags: Array<String> = FixedFlags.of(fn, _shape, _ifKinds);
		final held: Array<QueryNode> = [];
		final escapes: Array<QueryNode> = [];
		var leaks: Bool = false;
		for (bits in 0...1 << flags.length) {
			_decided = [for (i => f in flags) f => bits & (1 << i) != 0];
			reset(acquireFrom, releaseFroms, raisingFroms);
			if (sequence(fn.children, false) == true) _leaks = true;
			leaks = leaks || _leaks;
			for (n in _held) if (!held.contains(n)) held.push(n);
			for (n in _escapes) if (!escapes.contains(n)) escapes.push(n);
		}
		_decided = [];
		return { held: held, leaks: leaks, escapes: escapes };
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
		// a local declaration runs its initializer, in place: a `try`, `switch` or `if` there is walked like a statement
		if (_sequenceKinds.contains(kind) || _declKinds.contains(kind)) return sequence(kids, held);
		if (_exitKinds.contains(kind)) {
			final before: Null<Bool> = sequence(kids, held);
			final loop: Null<{ brk: Null<Bool>, cont: Null<Bool> }> = _jumpKinds.contains(kind) ? _loops[_loops.length - 1] : null;
			if (loop != null) {
				if (kind == _breakKind)
					loop.brk = join(loop.brk, before)
				else
					loop.cont = join(loop.cont, before);
				return null;
			}
			// a throw inside the body of a `try` whose `catch` provably catches it goes there, not out of the function
			if (before == true && !(_throwKinds.contains(kind) && raise(node))) _leaks = true;
			return null;
		}
		if (_ifKinds.contains(kind) && kids.length >= 2) {
			final cond: Null<Bool> = step(kids[0], held);
			if (cond == null) return null;
			final fixed: Null<Bool> = FixedFlags.decide(kids[0], _decided, _shape);
			if (fixed != null) return fixed ? step(kids[1], cond) : kids.length > 2 ? step(kids[2], cond) : cond;
			final otherwise: Null<Bool> = kids.length > 2 ? step(kids[2], cond) : cond;
			return join(step(kids[1], cond), otherwise);
		}
		if (_loopKinds.contains(kind)) {
			// iterate to a fixed point: a lock one pass leaves held is held on the next, from its first statement on; a
			// `continue` goes back to the head, a `break` past the end
			var entry: Bool = held;
			while (true) {
				final frame: { brk: Null<Bool>, cont: Null<Bool> } = { brk: null, cont: null };
				_loops.push(frame);
				final body: Null<Bool> = sequence(kids, entry);
				_loops.pop();
				final next: Bool = join(join(entry, body), frame.cont) == true;
				if (next == entry) return join(entry, frame.brk) == true;
				entry = next;
			}
		}
		if (_tryKinds.contains(kind) && kids.length > 0) {
			final frame: TryFrame = { catches: kids.filter(k -> k.kind == _catchKind), raised: false };
			final intercepts: Bool = frame.catches.length > 0;
			if (intercepts) _tries.push(frame);
			final body: Null<Bool> = step(kids[0], held);
			if (intercepts) _tries.pop();
			// a catch starts holding what the body was entered or left holding, or held where something in it threw: the
			// exception of a call no `raisingFroms` names is out of the model
			final entry: Bool = held || body == true || frame.raised;
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
	 * function, outside what a `catch` of a `try` in it provably catches (whose catches still run in the step's own context), and
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
		final catches: Array<QueryNode> = _tryKinds.contains(node.kind) ? kids.filter(k -> k.kind == _catchKind) : [];
		final dead: Null<(QueryNode, QueryNode) -> Bool> = _switchKinds.contains(node.kind) ? _deadBranch : null;
		for (i => k in kids) if (!(dead != null && dead(node, k))) {
			// what a `try` body raises meets its catches first
			final frame: Null<TryFrame> = i == 0 && catches.length > 0 ? { catches: catches, raised: false } : null;
			if (frame != null) _tries.push(frame);
			raisesInside(k, after);
			if (frame != null) _tries.pop();
		}
	}

	/**
	 * A throw (or a raising call) `node` reached holding the lock, met by the `try` bodies around it from the innermost
	 * out: each may run one of its catches, and the first whose catch provably catches the thrown value (`CatchTypes`)
	 * keeps it — whether one does is the answer. Else it escapes out of the body.
	 */
	private function raise(node: QueryNode): Bool {
		final thrown: Null<String> = _throwKinds.contains(node.kind) ? CatchTypes.thrownType(node, _shape) : null;
		var at: Int = _tries.length;
		while (at-- > 0) {
			final frame: TryFrame = _tries[at];
			frame.raised = true;
			if (CatchTypes.anyCatches(frame.catches, thrown, _shape, _exhaustive?.types())) return true;
		}
		if (!_escapes.contains(node)) _escapes.push(node);
		return false;
	}

	private function reset(acquireFrom: Int, releaseFroms: Array<Int>, raisingFroms: Array<Int>): Void {
		_acquireFrom = acquireFrom;
		_releaseFroms = releaseFroms;
		_raisingFroms = raisingFroms;
		_held = [];
		_leaks = false;
		_escapes = [];
		_loops = [];
		_tries = [];
	}

	/** Whether `node` holds a path out of the body — an exit statement not inside a nested function. */
	private function exits(node: QueryNode): Bool {
		return node.children.exists(k -> !_nestedFnKinds.contains(k.kind) && (_exitKinds.contains(k.kind) || exits(k)));
	}

	/** The kinds walked as their children in order: local declarations (their initializer) and array literals. */
	private static function inPlaceKindsOf(shape: RefShape): Array<String> {
		return (shape.localDeclKinds ?? []).concat(shape.arrayLiteralKind == null ? [] : [shape.arrayLiteralKind]);
	}

	/** The branches `exhaustive` says no value reaches, in the function node `fn` (graph id `fnId`). */
	private static function deadIn(exhaustive: ExhaustiveSwitches, fn: QueryNode, fnId: String): (QueryNode, QueryNode) -> Bool {
		return (sw, branch) -> exhaustive.dead(fn, fnId, sw, branch);
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

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
}

/**
 * The path-aware extent of a lock held inside ONE function body: a may-held walk over the statement structure from the
 * acquire call, where a release call clears the lock on ITS path only — `if (c) { m.release(); return; }` leaves every
 * statement after the `if` inside the window, which a source-order cut at the first release would drop.
 *
 * Over-approximates in the held direction wherever the structure is not modelled: a construct the walk does not know is
 * one opaque step (a release nested in it releases nothing, every call in it counts as held), a loop may run its body
 * zero or more times, a `catch` starts from what its `try` was entered or left holding, a loop jump counts as leaving
 * the body, and so does a `throw`. An exception a CALL raises is out of the model: a `catch` sees none from between
 * an acquire and a release inside its `try`, since every call may raise one and no written path says where. A body
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
	private final _catchKind: Null<String>;
	private final _regionKind: Null<String>;
	private final _callKind: Null<String>;

	private var _acquireFrom: Int = -1;
	private var _releaseFroms: Array<Int> = [];
	private var _held: Array<QueryNode> = [];
	private var _leaks: Bool = false;

	public function new(shape: RefShape, flow: ControlFlowSupport) {
		// an expression body is a sequence of the one expression it holds
		_sequenceKinds = flow.blockKinds()
			.concat(shape.exprStatementKind == null ? [] : [shape.exprStatementKind])
			.concat(shape.expressionBodyKinds ?? []);
		_ifKinds = (
			shape.ifStatementKinds ?? []
		).concat(shape.ifExpressionKinds ?? []).concat(shape.ternaryKind == null ? [] : [shape.ternaryKind]);
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
		_catchKind = shape.catchClauseKind;
		_regionKind = shape.conditionalMemberKind;
		_callKind = shape.callKind;
	}

	/**
	 * The window of the acquire call starting at `acquireFrom` in the function node `fn`, which `releaseFroms` (the
	 * starts of the calls releasing the same lock) close on their own path. Null when the grammar names no exit kinds,
	 * so no path out of the body can be recognised: the caller must then assume the lock is held anywhere.
	 */
	public function trace(fn: QueryNode, acquireFrom: Int, releaseFroms: Array<Int>): Null<HeldWindow> {
		if (_exitKinds.length == 0) return null;
		_acquireFrom = acquireFrom;
		_releaseFroms = releaseFroms;
		_held = [];
		_leaks = false;
		if (sequence(fn.children, false) == true) _leaks = true;
		return { held: _held, leaks: _leaks };
	}

	/**
	 * Whether every path through the function node `fn` gives back a lock held on entry: one of the calls starting at
	 * `releaseFroms` runs on each way out of the body. False when the grammar names no exit kinds.
	 */
	public function releasesOnEveryPath(fn: QueryNode, releaseFroms: Array<Int>): Bool {
		if (_exitKinds.length == 0) return false;
		_acquireFrom = -1;
		_releaseFroms = releaseFroms;
		_held = [];
		_leaks = false;
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
			if (before == true) _leaks = true;
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
			final body: Null<Bool> = step(kids[0], held);
			// a catch starts holding what the body was entered or left holding: a call's own exception is out of the model
			final entry: Bool = held || body == true;
			var out: Null<Bool> = body;
			for (i in 1...kids.length)
				out = join(out, kids[i].kind == _catchKind ? sequence(kids[i].children, entry) : step(kids[i], entry));
			return out;
		}
		if (_switchKinds.contains(kind)) {
			final subject: Null<Bool> = sequence([for (k in kids) if (!_branchKinds.contains(k.kind)) k], held);
			if (subject == null) return null;
			var out: Null<Bool> = subject;
			for (k in kids) if (_branchKinds.contains(k.kind)) out = join(out, sequence(k.children, subject));
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
	 * afterwards unless it IS a release call, and leaking when a path out of the body starts inside it.
	 */
	private function opaque(node: QueryNode, held: Bool): Bool {
		final span: Null<Span> = node.span;
		if (held && node.kind == _callKind && span != null && _releaseFroms.contains(span.from)) return false;
		_held.push(node);
		if (!_nestedFnKinds.contains(node.kind) && exits(node)) _leaks = true;
		return true;
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

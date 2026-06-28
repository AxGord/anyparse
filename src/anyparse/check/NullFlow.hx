package anyparse.check;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;

using Lambda;

/**
 * The null facts holding at one visited node's entry, queried by a consumer.
 * `nonNull(name)` answers whether `name` is provably non-null by flow there;
 * `isNull(name)` whether it is provably null. Both honour the closure-captured
 * exclusion. At most one is ever true for a given name (a name is `NonNull`,
 * `Null`, or `Unknown`).
 */
typedef NullFacts = {
	var nonNull: String -> Bool;
	var isNull: String -> Bool;
}

/**
 * The per-path fact lattice carried through a `NullFlow` walk: the set of names
 * provably `NonNull` and the disjoint set provably `Null` at the current point.
 * A name absent from both is `Unknown`. Every transfer keeps the two sets
 * disjoint (marking one polarity clears the other).
 */
private typedef FlowState = {
	var nonNull: Array<String>;
	var known: Array<String>;
}

/**
 * Per-function context for one `NullFlow` walk: the grammar-derived node-kind
 * sets, the per-function set of names mutated inside a nested closure
 * (`captured`, excluded from narrowing), and the consumer `visit` callback.
 * Built once per analyzed function body.
 */
private typedef FlowCtx = {
	var identKind: String;
	var assignKind: Null<String>;
	var notEqKind: Null<String>;
	var eqKind: Null<String>;
	var nullLitKind: Null<String>;
	var parenKind: Null<String>;
	var writeKinds: Array<String>;
	var localDeclKinds: Array<String>;
	var ifKinds: Array<String>;
	var loopKinds: Array<String>;
	var branchyKinds: Array<String>;
	var blockKinds: Array<String>;
	var controlExitKinds: Array<String>;
	var nonNullRhsKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var nestedFnKinds: Array<String>;
	var captured: Array<String>;
	var ownNames: Array<String>;
	var visit: (QueryNode, NullFacts) -> Void;
}

/**
 * Intra-procedural null-flow analysis for the analysis layer. Walks each
 * function body in flow order, maintaining a per-variable-name fact lattice,
 * and invokes a consumer `visit` callback at every node with the facts holding
 * **at that node's entry**.
 *
 * ## What it proves
 *
 * The lattice is three-valued per name: `NonNull`, `Null`, or `Unknown`. A name
 * is `NonNull`-by-flow at a point when it is non-null on **every** path reaching
 * it, and `Null`-by-flow when it is null on every such path — each established
 * only by a flow event: a guard narrowing a branch (a `!= null` then-arm / `== null`
 * else-arm proves non-null; the mirror proves null), or an assignment of a
 * syntactically definite value (`new T(...)` / a non-null literal is non-null,
 * the `null` literal is null). It seeds **no** facts from declared types —
 * declared-non-null is the point-wise checks' domain
 * (`TypeResolver.isProvablyNonNull`); this engine is strictly the flow-only
 * complement, so a flow consumer never duplicates a point-wise finding.
 *
 * ## Soundness invariant
 *
 * Flag only what holds on all paths. Every source of uncertainty collapses a
 * name to `Unknown` (a safe miss, never a false positive):
 *
 * - **Name-keyed, not binding-keyed.** Facts are keyed by variable name. Any
 *   write to a name — even one a `bindingSpan` resolver would attribute to a
 *   different same-named sibling-scope local — clears the fact on both
 *   polarities. Over-killing is a safe miss; under-killing (the unsound
 *   direction) cannot happen.
 * - **Joins (loops have no fixpoint).** After an `if`, the two arms' exit states
 *   are intersected per polarity (a name keeps a polarity only if it held it on
 *   both fall-through paths), and an arm that returns / throws contributes no
 *   path — so `if (x == null) return;` narrows the fall-through to non-null.
 *   `switch` / `try` clear every name assigned inside (conservative); a loop
 *   clears every name it assigns *before* the body, so a back-edge never carries
 *   a stale fact.
 * - **Closures.** A name mutated inside any nested function value is excluded
 *   from both polarities for the whole function (a closure call could reassign it).
 * - **Opaque subtrees.** Macro-reification (`RefShape.opaqueKinds`) is not
 *   descended into.
 *
 * Pure, stateless class (mirrors `TypeResolver`).
 */
@:nullSafety(Strict)
final class NullFlow {

	/** Expression kinds whose value can never be null — a safe non-null assignment RHS. */
	private static final NON_NULL_RHS_KINDS: Array<String> = [
		'NewExpr',
		'ArrayExpr',
		'ObjectLit',
		'DoubleStringExpr',
		'SingleStringExpr',
		'IntLit',
		'FloatLit',
		'HexLit',
		'BoolLit'
	];

	/** Nested function-value kinds — a separate flow context; their bodies are not walked with the outer state. */
	private static final NESTED_FN_KINDS: Array<String> = [
		'FnExpr',
		'NamedFnExpr',
		'ThinParenLambdaExpr',
		'ParenLambdaExpr',
		'LocalFnStmt',
		'LocalInlineFnStmt'
	];

	/** Branch constructs with two mutually-exclusive value arms — analyzed with isolated branch states. */
	private static final IF_KINDS: Array<String> = ['IfStmt', 'IfExpr', 'Ternary'];

	/** Loop constructs — every name they assign is cleared before the body so a back-edge carries no stale fact. */
	private static final LOOP_KINDS: Array<String> = ['WhileStmt', 'DoWhileStmt', 'ForStmt', 'WhileExpr', 'ForExpr'];

	/** Multi-branch constructs analyzed with one isolated state per branch. */
	private static final BRANCHY_KINDS: Array<String> = [
		'SwitchStmt',
		'SwitchStmtBare',
		'SwitchExpr',
		'SwitchExprBare',
		'TryCatchStmt',
		'TryCatchStmtBare',
		'TryExpr'
	];

	/** Sequential statement-list containers — children share one running state. */
	private static final BLOCK_KINDS: Array<String> = ['BlockBody', 'BlockStmt', 'BlockExpr'];

	private function new() {}

	/**
	 * Walk every function unit in `root` (`RefShape.functionKinds`) in flow
	 * order, calling `visit(node, facts)` pre-order at each node, where `facts`
	 * answers whether a name is provably non-null (`facts.nonNull`) or provably
	 * null (`facts.isNull`) by flow at that node's entry. A consumer inspects
	 * only the node kinds it cares about. A grammar lacking the required shape
	 * fields makes this a no-op.
	 */
	public static function analyze(root: QueryNode, shape: RefShape, visit: (QueryNode, NullFacts) -> Void): Void {
		final identKind: Null<String> = shape.identKind;
		if (identKind == null) return;
		final functionKinds: Array<String> = shape.functionKinds ?? [];
		final bodyKinds: Array<String> = shape.functionBodyKinds ?? [];
		if (functionKinds.length == 0 || bodyKinds.length == 0) return;
		final id: String = identKind;
		final paramKinds: Array<String> = shape.paramKinds ?? [];
		function findFns(node: QueryNode): Void {
			if (functionKinds.contains(node.kind)) {
				final body: Null<QueryNode> = node.children.find(c -> bodyKinds.contains(c.kind));
				if (body != null) {
					final paramNames: Array<String> = [];
					for (c in node.children) {
						final nm: Null<String> = c.name;
						if (paramKinds.contains(c.kind) && nm != null) paramNames.push(nm);
					}
					analyzeBody(body, shape, id, paramNames, visit);
				}
			}
			for (c in node.children) findFns(c);
		}
		findFns(root);
	}

	/**
	 * For a binary comparison whose one operand is the null literal and the other a
	 * plain identifier, that identifier node; null otherwise. The shared recogniser of
	 * an `x != null` / `x == null` comparison for the null-flow consumers.
	 */
	public static function nullComparisonOperand(node: QueryNode, identKind: String, nullLitKind: Null<String>): Null<QueryNode> {
		if (node.children.length != 2 || nullLitKind == null) return null;
		final nullLit: String = nullLitKind;
		final left: QueryNode = node.children[0];
		final right: QueryNode = node.children[1];
		final leftIsNull: Bool = left.kind == nullLit;
		final rightIsNull: Bool = right.kind == nullLit;
		if (leftIsNull == rightIsNull) return null;
		final operand: QueryNode = leftIsNull ? right : left;
		return operand.kind == identKind ? operand : null;
	}

	/**
	 * Analyze one function body from a fresh (all-`Unknown`) entry state. Only the
	 * unit's own names (its parameters plus locally-declared `var`/`final`s) are
	 * ever narrowed — a captured outer variable or an implicit-`this` field is a
	 * non-local a call could mutate, so the engine leaves it `Unknown` (mirroring
	 * the language's own strict null-safety, which narrows locals but not fields).
	 */
	private static function analyzeBody(
		body: QueryNode, shape: RefShape, identKind: String, paramNames: Array<String>, visit: (QueryNode, NullFacts) -> Void
	): Void {
		final localDeclKinds: Array<String> = shape.localDeclKinds ?? [];
		final ctx: FlowCtx = {
			identKind: identKind,
			assignKind: shape.assignKind,
			eqKind: shape.eqKind,
			notEqKind: shape.notEqKind,
			nullLitKind: shape.nullLiteralKind,
			parenKind: shape.parenKind,
			writeKinds: shape.writeParentKinds ?? [],
			localDeclKinds: localDeclKinds,
			ifKinds: IF_KINDS,
			loopKinds: LOOP_KINDS,
			branchyKinds: BRANCHY_KINDS,
			blockKinds: BLOCK_KINDS,
			controlExitKinds: shape.controlExitKinds ?? [],
			nonNullRhsKinds: NON_NULL_RHS_KINDS,
			opaqueKinds: shape.opaqueKinds ?? [],
			nestedFnKinds: NESTED_FN_KINDS,
			captured: collectCaptured(body, identKind, shape.writeParentKinds ?? []),
			ownNames: paramNames.concat(collectDeclared(body, localDeclKinds)),
			visit: visit
		};
		final state: FlowState = { nonNull: [], known: [] };
		walk(body, state, ctx);
	}

	/**
	 * Walk `node`, calling `ctx.visit` at it with the facts in `state`, then
	 * apply its flow transfer — mutating `state` in place to a sound
	 * over-approximation of the post-state.
	 */
	private static function walk(node: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		final kind: String = node.kind;
		if (ctx.opaqueKinds.contains(kind) || ctx.nestedFnKinds.contains(kind)) {
			killWritten(node, state, ctx);
			return;
		}
		final facts: NullFacts = {
			nonNull: n -> ctx.ownNames.contains(n) && !ctx.captured.contains(n) && state.nonNull.contains(n),
			isNull: n -> ctx.ownNames.contains(n) && !ctx.captured.contains(n) && state.known.contains(n)
		};
		ctx.visit(node, facts);
		if (ctx.writeKinds.contains(kind))
			handleWrite(node, state, ctx);
		else if (ctx.localDeclKinds.contains(kind))
			handleDecl(node, state, ctx);
		else if (ctx.ifKinds.contains(kind))
			handleIf(node, state, ctx);
		else if (ctx.loopKinds.contains(kind))
			handleLoop(node, state, ctx);
		else if (ctx.branchyKinds.contains(kind))
			handleBranchy(node, state, ctx);
		else if (ctx.blockKinds.contains(kind))
			handleBlock(node, state, ctx);
		else
			for (c in node.children) walk(c, state, ctx);
	}

	/** Assignment / compound-assignment / increment: narrow the target to `NonNull` for a plain assign of a non-null value, to `Null` for a plain assign of the null literal, else clear it on both polarities. */
	private static function handleWrite(node: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		for (c in node.children) walk(c, state, ctx);
		if (node.children.length == 0) return;
		final target: QueryNode = node.children[0];
		final name: Null<String> = target.name;
		if (target.kind != ctx.identKind || name == null) return;
		final rhs: Null<QueryNode> = node.children.length >= 2 ? node.children[1] : null;
		if (node.kind == ctx.assignKind && isNonNullRhs(rhs, ctx))
			markNonNull(state, name);
		else if (node.kind == ctx.assignKind && isNullLitRhs(rhs, ctx))
			markKnown(state, name);
		else
			clearName(state, name);
	}

	/** Local declaration: set the declared name to `NonNull` for a non-null initializer, to `Null` for a null-literal initializer, else clear both. */
	private static function handleDecl(node: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		final init: Null<QueryNode> = node.children.length >= 1 ? node.children[0] : null;
		if (init != null) walk(init, state, ctx);
		final name: Null<String> = node.name;
		if (name == null) return;
		if (isNonNullRhs(init, ctx))
			markNonNull(state, name);
		else if (isNullLitRhs(init, ctx))
			markKnown(state, name);
		else
			clearName(state, name);
	}

	/** `if` / ternary: narrow each arm by the condition's `!= null` / `== null` guards (both polarities); analyze each arm in isolation; join the arm-exit states. */
	private static function handleIf(node: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		if (node.children.length < 2) {
			for (c in node.children) walk(c, state, ctx);
			killWritten(node, state, ctx);
			return;
		}
		final cond: QueryNode = node.children[0];
		final thenArm: QueryNode = node.children[1];
		final elseArm: Null<QueryNode> = node.children.length > 2 ? node.children[2] : null;
		walk(cond, state, ctx);
		// Then-arm: narrow by the condition's conjuncts — `!= null` proves non-null,
		// `== null` proves null — walked to its exit state.
		final thenState: FlowState = copyState(state);
		final thenNonNull: Array<String> = [];
		collectNarrow(cond, thenNonNull, ctx, ctx.notEqKind, 'And');
		for (n in thenNonNull) markNonNull(thenState, n);
		final thenKnown: Array<String> = [];
		collectNarrow(cond, thenKnown, ctx, ctx.eqKind, 'And');
		for (n in thenKnown) markKnown(thenState, n);
		walk(thenArm, thenState, ctx);
		// Else path: the negated condition (`!(a || b)` = `!a && !b`), so an `== null`
		// disjunct proves non-null and a `!= null` disjunct proves null.
		final elseState: FlowState = copyState(state);
		final elseNonNull: Array<String> = [];
		collectNarrow(cond, elseNonNull, ctx, ctx.eqKind, 'Or');
		for (n in elseNonNull) markNonNull(elseState, n);
		final elseKnown: Array<String> = [];
		collectNarrow(cond, elseKnown, ctx, ctx.notEqKind, 'Or');
		for (n in elseKnown) markKnown(elseState, n);
		if (elseArm != null) walk(elseArm, elseState, ctx);
		// Join: a fact holds after the `if` only if it holds on every path that falls
		// through to here. An arm that returns / throws contributes no path, so the
		// surviving arm's state passes through unintersected — this gives early-return
		// narrowing (`if (x == null) return;` leaves x non-null after).
		final thenExits: Bool = armExits(thenArm, ctx);
		final elseExits: Bool = elseArm != null && armExits(elseArm, ctx);
		final post: FlowState = if (thenExits && elseExits)
			{ nonNull: [], known: [] };
		else if (thenExits)
			elseState;
		else if (elseExits)
			thenState;
		else
			intersect(thenState, elseState);
		setState(state, post);
	}

	/** Loop: clear every name the loop assigns before walking it (back-edge soundness); the post-state is that cleared state. */
	private static function handleLoop(node: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		killWritten(node, state, ctx);
		final bodyState: FlowState = copyState(state);
		for (c in node.children) walk(c, bodyState, ctx);
	}

	/** `switch` / `try`: analyze each child branch in an isolated copy of the entry state; clear all names assigned anywhere in the construct. */
	private static function handleBranchy(node: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		for (c in node.children) walk(c, copyState(state), ctx);
		killWritten(node, state, ctx);
	}

	/** Statement-list block: children share one running state; block-local declarations are cleared on exit so their facts do not leak out. */
	private static function handleBlock(node: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		for (c in node.children) walk(c, state, ctx);
		for (n in collectDeclared(node, ctx.localDeclKinds)) clearName(state, n);
	}

	/** Whether `rhs` is a syntactically non-null expression (a constructor or a non-null literal). */
	private static function isNonNullRhs(rhs: Null<QueryNode>, ctx: FlowCtx): Bool {
		return rhs != null && ctx.nonNullRhsKinds.contains(rhs.kind);
	}

	/** Whether `rhs` is the null literal — a syntactically definite-null assignment value. */
	private static function isNullLitRhs(rhs: Null<QueryNode>, ctx: FlowCtx): Bool {
		return rhs != null && ctx.nullLitKind != null && rhs.kind == ctx.nullLitKind;
	}

	/** Clear every name written anywhere in `node`'s subtree (any write-kind whose first child is a plain identifier) on both polarities. */
	private static function killWritten(node: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		if (ctx.writeKinds.contains(node.kind) && node.children.length >= 1) {
			final target: QueryNode = node.children[0];
			final name: Null<String> = target.name;
			if (target.kind == ctx.identKind && name != null) clearName(state, name);
		}
		for (c in node.children) killWritten(c, state, ctx);
	}

	/** The names locally declared anywhere in `node`'s subtree. */
	private static function collectDeclared(node: QueryNode, localDeclKinds: Array<String>): Array<String> {
		final out: Array<String> = [];
		function walkDecl(n: QueryNode): Void {
			final name: Null<String> = n.name;
			if (localDeclKinds.contains(n.kind) && name != null) out.push(name);
			for (c in n.children) walkDecl(c);
		}
		walkDecl(node);
		return out;
	}

	/** The names mutated inside any nested function value within `body` — excluded from narrowing for the whole function. */
	private static function collectCaptured(body: QueryNode, identKind: String, writeKinds: Array<String>): Array<String> {
		final out: Array<String> = [];
		function collectWrites(n: QueryNode): Void {
			if (writeKinds.contains(n.kind) && n.children.length >= 1) {
				final target: QueryNode = n.children[0];
				final name: Null<String> = target.name;
				if (target.kind == identKind && name != null) out.push(name);
			}
			for (c in n.children) collectWrites(c);
		}
		function walkBody(n: QueryNode): Void {
			if (NESTED_FN_KINDS.contains(n.kind))
				collectWrites(n);
			else
				for (c in n.children) walkBody(c);
		}
		walkBody(body);
		return out;
	}

	/**
	 * Collect into `out` the names a condition proves non-null for one branch — the
	 * then-arm via `(notEqKind, 'And')` (each `!= null` conjunct), the else-arm via
	 * `(eqKind, 'Or')` (each `== null` disjunct — the negated condition). A bare
	 * comparison, every matching child of the combining operator, and a parenthesized
	 * wrapper are descended; any other shape narrows nothing. Soundness rests on the
	 * duality: the then-arm holds the `&&` of the condition, the else-arm the negation
	 * (`!(a || b)` = `!a && !b`), so an `== null` disjunct proves non-null when false.
	 */
	private static function collectNarrow(
		cond: QueryNode, out: Array<String>, ctx: FlowCtx, cmpKind: Null<String>, combineKind: String
	): Void {
		final kind: String = cond.kind;
		if (cmpKind != null && kind == cmpKind) {
			final operand: Null<QueryNode> = nullComparisonOperand(cond, ctx.identKind, ctx.nullLitKind);
			if (operand != null) {
				final nm: Null<String> = operand.name;
				if (nm != null) out.push(nm);
			}
		} else if (kind == combineKind) {
			for (c in cond.children) collectNarrow(c, out, ctx, cmpKind, combineKind);
		} else if (ctx.parenKind != null && kind == ctx.parenKind && cond.children.length == 1) {
			collectNarrow(cond.children[0], out, ctx, cmpKind, combineKind);
		}
	}

	/** Record `name` as `NonNull` in `state`, clearing any `Null` fact (the two sets stay disjoint), deduplicated. */
	private static inline function markNonNull(state: FlowState, name: String): Void {
		if (!state.nonNull.contains(name)) state.nonNull.push(name);
		state.known.remove(name);
	}

	/** Record `name` as `Null` in `state`, clearing any `NonNull` fact (the two sets stay disjoint), deduplicated. */
	private static inline function markKnown(state: FlowState, name: String): Void {
		if (!state.known.contains(name)) state.known.push(name);
		state.nonNull.remove(name);
	}

	/** Drop every fact about `name` — it becomes `Unknown`. */
	private static inline function clearName(state: FlowState, name: String): Void {
		state.nonNull.remove(name);
		state.known.remove(name);
	}

	/** A deep copy of `state` — an isolated branch state the caller can mutate without affecting the original. */
	private static inline function copyState(state: FlowState): FlowState {
		return { nonNull: state.nonNull.copy(), known: state.known.copy() };
	}

	/**
	 * Whether `arm` definitely transfers control out instead of falling through to the
	 * statement after the enclosing `if` — a `return` / `throw` (`RefShape.controlExitKinds`),
	 * or a block whose last statement does. Conservative: anything it cannot prove exits
	 * (including `break` / `continue`) is treated as falling through, which only ever loses
	 * precision in the join, never soundness.
	 */
	private static function armExits(arm: QueryNode, ctx: FlowCtx): Bool {
		if (ctx.controlExitKinds.contains(arm.kind)) return true;
		if (ctx.blockKinds.contains(arm.kind) && arm.children.length > 0) return armExits(arm.children[arm.children.length - 1], ctx);
		return false;
	}

	/** The facts holding on both `a` and `b` — a name keeps a polarity after a join only if it held it on both arms. */
	private static function intersect(a: FlowState, b: FlowState): FlowState {
		return {
			nonNull: [for (n in a.nonNull) if (b.nonNull.contains(n)) n],
			known: [for (n in a.known) if (b.known.contains(n)) n]
		};
	}

	/** Replace the contents of `state` in place with `next` (the running state is mutated for the caller). */
	private static inline function setState(state: FlowState, next: FlowState): Void {
		state.nonNull.resize(0);
		for (n in next.nonNull) state.nonNull.push(n);
		state.known.resize(0);
		for (n in next.known) state.known.push(n);
	}

}

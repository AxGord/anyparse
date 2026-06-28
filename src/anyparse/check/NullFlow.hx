package anyparse.check;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;

using Lambda;

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
	var nullLitKind: Null<String>;
	var parenKind: Null<String>;
	var writeKinds: Array<String>;
	var localDeclKinds: Array<String>;
	var ifKinds: Array<String>;
	var loopKinds: Array<String>;
	var branchyKinds: Array<String>;
	var blockKinds: Array<String>;
	var nonNullRhsKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var nestedFnKinds: Array<String>;
	var captured: Array<String>;
	var visit: (QueryNode, String -> Bool) -> Void;
}

/**
 * Intra-procedural null-flow analysis for the analysis layer. Walks each
 * function body in flow order, maintaining a per-variable-name fact lattice,
 * and invokes a consumer `visit` callback at every node with a query into the
 * facts holding **at that node's entry**.
 *
 * ## What it proves
 *
 * A name is `NonNull`-by-flow at a point when it is non-null on **every** path
 * reaching that point — established only by a flow event: a `n != null` guard
 * narrowing the controlled branch, or an assignment of a syntactically non-null
 * value (`new T(...)`, a non-null literal). It seeds **no** facts from declared
 * types — declared-non-null is the point-wise checks' domain
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
 *   different same-named sibling-scope local — clears the fact. Over-killing is
 *   a safe miss; under-killing (the unsound direction) cannot happen.
 * - **Conservative joins (no fixpoint yet).** After an `if` / `switch` / `try`
 *   every name assigned anywhere inside is cleared; a loop clears every name it
 *   assigns *before* the body, so a back-edge never carries a stale fact.
 * - **Closures.** A name mutated inside any nested function value is excluded
 *   from narrowing for the whole function (a closure call could reassign it).
 * - **Opaque subtrees.** Macro-reification (`RefShape.opaqueKinds`) is not
 *   descended into.
 *
 * Pure, stateless class (mirrors `TypeResolver`). The lattice is two-valued
 * here — `Unknown` (a name absent from the set) and `NonNull` (present in it); a third `Null` state is reserved for later flow consumers.
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
	private static final NESTED_FN_KINDS: Array<String> = ['FnExpr', 'FnDecl', 'LocalFnStmt', 'ThinParenLambdaExpr', 'ParenLambdaExpr'];

	/** Branch constructs with two mutually-exclusive value arms — analyzed with isolated branch states. */
	private static final IF_KINDS: Array<String> = ['IfStmt', 'IfExpr', 'Ternary'];

	/** Loop constructs — every name they assign is cleared before the body so a back-edge carries no stale fact. */
	private static final LOOP_KINDS: Array<String> = ['WhileStmt', 'DoWhileStmt', 'ForStmt', 'WhileExpr', 'ForExpr', 'DoWhileExpr'];

	/** Multi-branch constructs analyzed with one isolated state per branch. */
	private static final BRANCHY_KINDS: Array<String> = ['SwitchStmt', 'SwitchExpr', 'TryCatchStmt', 'TryCatchExpr'];

	/** Sequential statement-list containers — children share one running state. */
	private static final BLOCK_KINDS: Array<String> = ['BlockBody', 'BlockStmt', 'BlockExpr'];

	private function new() {}

	/**
	 * Walk every function unit in `root` (`RefShape.functionKinds`) in flow
	 * order, calling `visit(node, query)` pre-order at each node, where
	 * `query(name)` answers whether `name` is provably non-null by flow at that
	 * node's entry. A consumer inspects only the node kinds it cares about. A
	 * grammar lacking the required shape fields makes this a no-op.
	 */
	public static function analyze(root: QueryNode, shape: RefShape, visit: (QueryNode, String -> Bool) -> Void): Void {
		final identKind: Null<String> = shape.identKind;
		if (identKind == null) return;
		final functionKinds: Array<String> = shape.functionKinds ?? [];
		final bodyKinds: Array<String> = shape.functionBodyKinds ?? [];
		if (functionKinds.length == 0 || bodyKinds.length == 0) return;
		final id: String = identKind;
		function findFns(node: QueryNode): Void {
			if (functionKinds.contains(node.kind)) {
				final body: Null<QueryNode> = node.children.find(c -> bodyKinds.contains(c.kind));
				if (body != null) analyzeBody(body, shape, id, visit);
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

	/** Analyze one function body from a fresh (all-`Unknown`) entry state. */
	private static function analyzeBody(
		body: QueryNode, shape: RefShape, identKind: String, visit: (QueryNode, String -> Bool) -> Void
	): Void {
		final ctx: FlowCtx = {
			identKind: identKind,
			assignKind: shape.assignKind,
			notEqKind: shape.notEqKind,
			nullLitKind: shape.nullLiteralKind,
			parenKind: shape.parenKind,
			writeKinds: shape.writeParentKinds ?? [],
			localDeclKinds: shape.localDeclKinds ?? [],
			ifKinds: IF_KINDS,
			loopKinds: LOOP_KINDS,
			branchyKinds: BRANCHY_KINDS,
			blockKinds: BLOCK_KINDS,
			nonNullRhsKinds: NON_NULL_RHS_KINDS,
			opaqueKinds: shape.opaqueKinds ?? [],
			nestedFnKinds: NESTED_FN_KINDS,
			captured: collectCaptured(body, identKind, shape.writeParentKinds ?? []),
			visit: visit
		};
		final state: Array<String> = [];
		walk(body, state, ctx);
	}

	/**
	 * Walk `node`, calling `ctx.visit` at it with the facts in `state`, then
	 * apply its flow transfer — mutating `state` in place to a sound
	 * over-approximation of the post-state.
	 */
	private static function walk(node: QueryNode, state: Array<String>, ctx: FlowCtx): Void {
		final kind: String = node.kind;
		if (ctx.opaqueKinds.contains(kind) || ctx.nestedFnKinds.contains(kind)) {
			killWritten(node, state, ctx);
			return;
		}
		ctx.visit(node, n -> !ctx.captured.contains(n) && state.contains(n));
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

	/** Assignment / compound-assignment / increment: narrow the target to `NonNull` only for a plain assign of a non-null RHS, else clear it. */
	private static function handleWrite(node: QueryNode, state: Array<String>, ctx: FlowCtx): Void {
		for (c in node.children) walk(c, state, ctx);
		if (node.children.length == 0) return;
		final target: QueryNode = node.children[0];
		final name: Null<String> = target.name;
		if (target.kind != ctx.identKind || name == null) return;
		final rhs: Null<QueryNode> = node.children.length >= 2 ? node.children[1] : null;
		if (node.kind == ctx.assignKind && isNonNullRhs(rhs, ctx))
			markNonNull(state, name);
		else
			state.remove(name);
	}

	/** Local declaration: set the declared name to `NonNull` for a non-null initializer, else `Unknown`. */
	private static function handleDecl(node: QueryNode, state: Array<String>, ctx: FlowCtx): Void {
		final init: Null<QueryNode> = node.children.length >= 1 ? node.children[0] : null;
		if (init != null) walk(init, state, ctx);
		final name: Null<String> = node.name;
		if (name == null) return;
		if (isNonNullRhs(init, ctx))
			markNonNull(state, name);
		else
			state.remove(name);
	}

	/** `if` / ternary: narrow the then-arm by the condition's `!= null` guards; analyze each arm in isolation; clear all names assigned in the construct. */
	private static function handleIf(node: QueryNode, state: Array<String>, ctx: FlowCtx): Void {
		if (node.children.length < 2) {
			for (c in node.children) walk(c, state, ctx);
			killWritten(node, state, ctx);
			return;
		}
		final cond: QueryNode = node.children[0];
		final thenArm: QueryNode = node.children[1];
		final elseArm: Null<QueryNode> = node.children.length > 2 ? node.children[2] : null;
		walk(cond, state, ctx);
		final narrowed: Array<String> = [];
		guardNonNullNames(cond, narrowed, ctx);
		final thenState: Array<String> = state.copy();
		for (n in narrowed) markNonNull(thenState, n);
		walk(thenArm, thenState, ctx);
		if (elseArm != null) walk(elseArm, state.copy(), ctx);
		killWritten(node, state, ctx);
	}

	/** Loop: clear every name the loop assigns before walking it (back-edge soundness); the post-state is that cleared state. */
	private static function handleLoop(node: QueryNode, state: Array<String>, ctx: FlowCtx): Void {
		killWritten(node, state, ctx);
		final bodyState: Array<String> = state.copy();
		for (c in node.children) walk(c, bodyState, ctx);
	}

	/** `switch` / `try`: analyze each child branch in an isolated copy of the entry state; clear all names assigned anywhere in the construct. */
	private static function handleBranchy(node: QueryNode, state: Array<String>, ctx: FlowCtx): Void {
		for (c in node.children) walk(c, state.copy(), ctx);
		killWritten(node, state, ctx);
	}

	/** Statement-list block: children share one running state; block-local declarations are cleared on exit so their facts do not leak out. */
	private static function handleBlock(node: QueryNode, state: Array<String>, ctx: FlowCtx): Void {
		for (c in node.children) walk(c, state, ctx);
		for (n in collectDeclared(node, ctx)) state.remove(n);
	}

	/** Whether `rhs` is a syntactically non-null expression (a constructor or a non-null literal). */
	private static function isNonNullRhs(rhs: Null<QueryNode>, ctx: FlowCtx): Bool {
		return rhs != null && ctx.nonNullRhsKinds.contains(rhs.kind);
	}

	/** Clear every name written anywhere in `node`'s subtree (any write-kind whose first child is a plain identifier). */
	private static function killWritten(node: QueryNode, state: Array<String>, ctx: FlowCtx): Void {
		if (ctx.writeKinds.contains(node.kind) && node.children.length >= 1) {
			final target: QueryNode = node.children[0];
			final name: Null<String> = target.name;
			if (target.kind == ctx.identKind && name != null) state.remove(name);
		}
		for (c in node.children) killWritten(c, state, ctx);
	}

	/** The names locally declared anywhere in `node`'s subtree. */
	private static function collectDeclared(node: QueryNode, ctx: FlowCtx): Array<String> {
		final out: Array<String> = [];
		function walkDecl(n: QueryNode): Void {
			final name: Null<String> = n.name;
			if (ctx.localDeclKinds.contains(n.kind) && name != null) out.push(name);
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
	 * The names a condition proves non-null for its controlled (then / true)
	 * branch — a bare `n != null`, each `!= null` conjunct of an `&&`, through a
	 * parenthesized wrapper. An `||`, an `== null`, or any other shape narrows
	 * nothing.
	 */
	private static function guardNonNullNames(cond: QueryNode, out: Array<String>, ctx: FlowCtx): Void {
		final kind: String = cond.kind;
		if (kind == ctx.notEqKind) {
			final operand: Null<QueryNode> = nullComparisonOperand(cond, ctx.identKind, ctx.nullLitKind);
			if (operand != null) {
				final nm: Null<String> = operand.name;
				if (nm != null) out.push(nm);
			}
		} else if (kind == 'And') {
			for (c in cond.children) guardNonNullNames(c, out, ctx);
		} else if (ctx.parenKind != null && kind == ctx.parenKind && cond.children.length == 1) {
			guardNonNullNames(cond.children[0], out, ctx);
		}
	}

	/** Record `name` as `NonNull` in `state` (the set of names provably non-null by flow), deduplicated. */
	private static inline function markNonNull(state: Array<String>, name: String): Void {
		if (!state.contains(name)) state.push(name);
	}

}

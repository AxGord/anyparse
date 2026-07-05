package anyparse.check;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;

using Lambda;

import anyparse.runtime.Span;

/**
 * The null facts holding at one visited node's entry, queried by a consumer.
 * `nonNull(name)` answers whether `name` is provably non-null by flow there;
 * `isNull(name)` whether it is provably null; `isMaybeNull(name)` whether it came from a nullable source and is not yet narrowed non-null (a mechanism-A seed, empty for the flow checks that pass none). Both honour the closure-captured
 * exclusion. At most one of the three accessors is ever true for a given name (`NonNull`, `Null`, `MaybeNull`, or — none true — `Unknown`).
 */
typedef NullFacts = {
	var nonNull: String -> Bool;
	var isNull: String -> Bool;
	var isMaybeNull: String -> Bool;
}

/**
 * The per-path fact lattice carried through a `NullFlow` walk: the set of names
 * provably `NonNull` and the disjoint set provably `Null` at the current point.
 * A name in the third `maybe` set is `MaybeNull`; a name absent from all three is `Unknown`. Every transfer keeps the three sets pairwise disjoint (marking one polarity clears the others).
 */
private typedef FlowState = {
	var nonNull: Array<String>;
	var known: Array<String>;
	var maybe: Array<String>;
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
	var declTypeChildKinds: Array<String>;
	var ifKinds: Array<String>;
	var loopKinds: Array<String>;
	var switchKinds: Array<String>;
	var tryKinds: Array<String>;
	var blockKinds: Array<String>;
	var controlExitKinds: Array<String>;
	var nonNullRhsKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var nestedFnKinds: Array<String>;
	var caseBranchKind: Null<String>;
	var defaultBranchKind: Null<String>;
	var plainCasePatternKind: Null<String>;
	var wildcardPatternName: Null<String>;
	var exprStmtKind: Null<String>;
	var loopJumpNames: Array<String>;
	var catchClauseKind: Null<String>;
	var nullCoalAssignKind: Null<String>;
	var nullCoalKind: Null<String>;
	var callKind: Null<String>;
	var fieldAccessKind: Null<String>;
	var nullAssertionCalls: Array<String>;
	var captured: Array<String>;
	var ownNames: Array<String>;
	var source: String;
	var nullableSourceRhs: Null<QueryNode -> Bool>;
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
 * The lattice is four-valued per name: `NonNull`, `Null`, `MaybeNull` (a value from a nullable source, pending a narrowing — populated only when a consumer supplies the mechanism-A seed), or `Unknown`. A name
 * is `NonNull`-by-flow at a point when it is non-null on **every** path reaching
 * it, and `Null`-by-flow when it is null on every such path — each established
 * only by a flow event: a guard narrowing a branch (a `!= null` then-arm / `== null`
 * else-arm proves non-null; the mirror proves null), or an assignment of a
 * syntactically definite value (`new T(...)` / a non-null literal is non-null,
 * the `null` literal is null; a `??=` of a non-null value leaves the target
 * non-null whichever side survives, and its right-hand side's effects are
 * joined in as conditional). It seeds **no** facts from declared types —
 * declared-non-null is the point-wise checks' domain
 * (`TypeResolver.isProvablyNonNull`); this engine is strictly the flow-only complement, so a flow consumer never duplicates a point-wise finding. The one exception is the optional `MaybeNull` seed (mechanism A): when a consumer supplies a `seed` predicate, a local assigned a value the predicate accepts (a nullable source) becomes `MaybeNull` until narrowed, backing the flow-sensitive `unguarded-nullable-deref` — inert for every consumer that passes no seed.
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
 *   direction) cannot happen. A binding the walk KNOWS shadows an outer name
 *   (a case-pattern capture, a catch variable, a declaration in a body that is
 *   not block-wrapped) is cleared at its scope's entry AND exit, so neither an
 *   outer fact leaks in nor a shadow-write fact leaks out.
 * - **Joins (loops have no fixpoint).** After an `if`, the two arms' exit states
 *   are intersected per polarity (a name keeps a polarity only if it held it on
 *   both fall-through paths), and an arm that exits — `return` / `throw` / a
 *   loop jump — contributes no path, so `if (x == null) return;` narrows the
 *   fall-through to non-null. A `switch` intersects its branches' exit states
 *   the same way, plus the no-branch-matched path unless a `default:` or an
 *   unguarded `case _:` proves exhaustiveness (a guarded wildcard never counts;
 *   names written inside case guards are cleared up front, since guards of
 *   earlier branches run during dispatch). A `try` intersects the body's exit
 *   state with each catch clause's — where a clause starts from the entry state
 *   with every name the body writes cleared, since the throw may fire at any
 *   point inside the body. A loop clears every name it assigns *before* the
 *   body, so a back-edge never carries a stale fact. A short-circuit boolean
 *   (`a && b` / `a || b`) walks its right-hand side as a conditional path — on
 *   a copy narrowed by the left side (`&&` as a then-arm, `||` as an else-arm) —
 *   and intersects the exit back, so a write inside the RHS never leaks a fact onto the skip path; a plain `??` fallback gets the same conditional join. Narrowing from a condition never keeps a fact for a name the condition itself writes — that comparison may predate the write.
 * - **Closures.** A name mutated inside any nested function value is excluded
 *   from both polarities for the whole function (a closure call could reassign it).
 * - **Opaque subtrees.** Macro-reification (`RefShape.opaqueKinds`) is not descended into, and metadata annotations (`META_KINDS`) are skipped entirely — their arguments are compile-time data, never runtime code.
 *
 * Pure, stateless class (mirrors `TypeResolver`).
 */
@:nullSafety(Strict)
final class NullFlow {

	/** Nested function-value kinds — a separate flow context; their bodies are not walked with the outer state. */
	public static final NESTED_FN_KINDS: Array<String> = [
		'FnExpr',
		'NamedFnExpr',
		'ThinParenLambdaExpr',
		'ParenLambdaExpr',
		'LocalFnStmt',
		'LocalInlineFnStmt'
	];

	/** Branch constructs with two mutually-exclusive value arms — analyzed with isolated branch states. */
	public static final IF_KINDS: Array<String> = ['IfStmt', 'IfExpr', 'Ternary'];

	/** Loop constructs — every name they assign is cleared before the body so a back-edge carries no stale fact. */
	public static final LOOP_KINDS: Array<String> = ['WhileStmt', 'DoWhileStmt', 'ForStmt', 'WhileExpr', 'ForExpr'];

	/** `switch` construct kinds — joined branch-per-branch by the flow walk (statement and expression forms, bare and parenthesized subjects). */
	public static final SWITCH_KINDS: Array<String> = ['SwitchStmt', 'SwitchStmtBare', 'SwitchExpr', 'SwitchExprBare'];

	/** `try` construct kinds — the body and each catch clause joined by the flow walk. */
	public static final TRY_KINDS: Array<String> = ['TryCatchStmt', 'TryCatchStmtBare', 'TryExpr'];

	/** Multi-branch construct kinds — the union of `SWITCH_KINDS` and `TRY_KINDS`; the `dead-store` liveness walk treats them uniformly. */
	public static final BRANCHY_KINDS: Array<String> = SWITCH_KINDS.concat(TRY_KINDS);

	/**
	 * Metadata annotation kinds (`@:name(args)` / `@:name` / raw) — their argument
	 * expressions are compile-time data, never runtime code, so the flow walks
	 * skip these subtrees entirely (no facts change, no consumer visits). Mirrors
	 * the plugin's `metaShape().metaKinds`. Shared with `DeadStore`.
	 */
	public static final META_KINDS: Array<String> = ['MetaCall', 'Meta', 'PlainMeta'];

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

	/** Sequential statement-list containers — children share one running state. */
	private static final BLOCK_KINDS: Array<String> = ['BlockBody', 'BlockStmt', 'BlockExpr'];

	/**
	 * The short-circuit boolean-and node kind — its right side is a conditional path, and then-arm narrowing combines over its conjuncts.
	 */
	private static final BOOL_AND_KIND: String = 'And';

	/**
	 * The short-circuit boolean-or node kind — its right side is a conditional path, and else-arm narrowing combines over its disjuncts.
	 */
	private static final BOOL_OR_KIND: String = 'Or';

	private function new() {}

	/**
	 * Walk every function unit in `root` (`RefShape.functionKinds`) in flow
	 * order, calling `visit(node, facts)` pre-order at each node, where `facts`
	 * answers whether a name is provably non-null (`facts.nonNull`) or provably
	 * null (`facts.isNull`) by flow at that node's entry. `source` is the file's
	 * verbatim text (multi-binding declarations are detected textually). A
	 * consumer inspects only the node kinds it cares about. A grammar lacking the
	 * required shape fields makes this a no-op.
	 */
	public static function analyze(
		root: QueryNode, shape: RefShape, source: String, visit: (QueryNode, NullFacts) -> Void, ?seed: (QueryNode) -> Bool
	): Void {
		final identKind: Null<String> = shape.identKind;
		if (identKind == null) return;
		final id: String = identKind;
		forEachFunctionUnit(root, shape, (body, paramNames) -> analyzeBody(body, shape, source, id, paramNames, visit, seed));
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
	 * The initializer expression of a local declaration node, or null when it has
	 * none. A declaration's initializer is its LAST child — a top-level
	 * anonymous-struct type annotation also projects as a child
	 * (`RefShape.declTypeChildKinds`), before the initializer, so the last child
	 * is the init only when it is not one of those. Shared with the `dead-store`
	 * liveness walk.
	 */
	public static function declInit(node: QueryNode, declTypeChildKinds: Array<String>): Null<QueryNode> {
		if (node.children.length == 0) return null;
		final last: QueryNode = node.children[node.children.length - 1];
		return declTypeChildKinds.contains(last.kind) ? null : last;
	}

	/**
	 * The names locally declared anywhere in `node`'s subtree, EXCLUDING nested
	 * function values — a closure-internal local is a different unit's binding
	 * (treating it as an own name would hijack a same-named outer field write).
	 * Shared with the `dead-store` liveness walk.
	 */
	public static function collectDeclared(node: QueryNode, localDeclKinds: Array<String>): Array<String> {
		final out: Array<String> = [];
		function walkDecl(n: QueryNode): Void {
			if (NESTED_FN_KINDS.contains(n.kind)) return;
			final name: Null<String> = n.name;
			if (localDeclKinds.contains(n.kind) && name != null) out.push(name);
			for (c in n.children) walkDecl(c);
		}
		walkDecl(node);
		return out;
	}

	/**
	 * Enumerate every function unit in `root` (`RefShape.functionKinds`), calling
	 * `each(body, paramNames)` with the unit's body node and its parameter names.
	 * The shared unit-discovery walk of the flow engines (`NullFlow` and the
	 * `dead-store` liveness walk).
	 */
	public static function forEachFunctionUnit(root: QueryNode, shape: RefShape, each: (QueryNode, Array<String>) -> Void): Void {
		final functionKinds: Array<String> = shape.functionKinds ?? [];
		final bodyKinds: Array<String> = shape.functionBodyKinds ?? [];
		if (functionKinds.length == 0 || bodyKinds.length == 0) return;
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
					each(body, paramNames);
				}
			}
			for (c in node.children) findFns(c);
		}
		findFns(root);
	}

	/**
	 * Whether a local declaration node declares MORE than one binding
	 * (`var a = 1, b = 2;`) — projected as a single node carrying only the FIRST
	 * binding's name with every binding's initializer as a child, so no
	 * per-binding init attribution is possible. Detected structurally (two or
	 * more non-type children) or textually (a comma in the declaration's source
	 * outside brackets and string literals — catches the one-child
	 * `var a, b = e;` form; a comma inside a generic annotation like
	 * `Map<Int, String>` also trips it, which only drops a fact — a safe miss).
	 * A node with no span reports multi (conservative).
	 */
	public static function isMultiBinding(node: QueryNode, source: String, declTypeChildKinds: Array<String>): Bool {
		var exprChildren: Int = 0;
		for (c in node.children) if (!declTypeChildKinds.contains(c.kind)) exprChildren++;
		if (exprChildren > 1) return true;
		final span: Null<Span> = node.span;
		if (span == null) return true;
		return hasTopLevelComma(source, span.from, span.to);
	}

	/**
	 * Analyze one function body from a fresh (all-`Unknown`) entry state. Only the
	 * unit's own names (its parameters plus locally-declared `var`/`final`s) are
	 * ever narrowed — a captured outer variable or an implicit-`this` field is a
	 * non-local a call could mutate, so the engine leaves it `Unknown` (mirroring
	 * the language's own strict null-safety, which narrows locals but not fields).
	 */
	private static function analyzeBody(
		body: QueryNode, shape: RefShape, source: String, identKind: String, paramNames: Array<String>,
		visit: (QueryNode, NullFacts) -> Void, seed: Null<(QueryNode) -> Bool>
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
			declTypeChildKinds: shape.declTypeChildKinds ?? [],
			ifKinds: IF_KINDS,
			loopKinds: LOOP_KINDS,
			switchKinds: SWITCH_KINDS,
			tryKinds: TRY_KINDS,
			blockKinds: BLOCK_KINDS,
			controlExitKinds: shape.controlExitKinds ?? [],
			nonNullRhsKinds: NON_NULL_RHS_KINDS,
			opaqueKinds: shape.opaqueKinds ?? [],
			nestedFnKinds: NESTED_FN_KINDS,
			caseBranchKind: shape.caseBranchKind,
			defaultBranchKind: shape.defaultBranchKind,
			plainCasePatternKind: shape.plainCasePatternKind,
			wildcardPatternName: shape.wildcardPatternName,
			exprStmtKind: shape.exprStatementKind,
			loopJumpNames: shape.loopJumpNames ?? [],
			catchClauseKind: shape.catchClauseKind,
			nullCoalAssignKind: shape.nullCoalAssignKind,
			nullCoalKind: shape.nullCoalesceKind,
			callKind: shape.callKind,
			fieldAccessKind: shape.fieldAccessKind,
			nullAssertionCalls: shape.nullAssertionCalls ?? [],
			captured: collectCaptured(body, identKind, shape.writeParentKinds ?? []),
			ownNames: paramNames.concat(collectDeclared(body, localDeclKinds)),
			source: source,
			nullableSourceRhs: seed,
			visit: visit
		};
		final state: FlowState = { nonNull: [], known: [], maybe: [] };
		walk(body, state, ctx);
	}

	/**
	 * Walk `node`, calling `ctx.visit` at it with the facts in `state`, then
	 * apply its flow transfer — mutating `state` in place to a sound
	 * over-approximation of the post-state.
	 */
	private static function walk(node: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		final kind: String = node.kind;
		if (META_KINDS.contains(kind)) return;
		if (ctx.opaqueKinds.contains(kind) || ctx.nestedFnKinds.contains(kind)) {
			killWritten(node, state, ctx);
			return;
		}
		visitNode(node, state, ctx);
		if (ctx.writeKinds.contains(kind))
			handleWrite(node, state, ctx);
		else if (ctx.localDeclKinds.contains(kind))
			handleDecl(node, state, ctx);
		else if (ctx.ifKinds.contains(kind))
			handleIf(node, state, ctx);
		else if (ctx.loopKinds.contains(kind))
			handleLoop(node, state, ctx);
		else if (ctx.switchKinds.contains(kind))
			handleSwitch(node, state, ctx);
		else if (ctx.tryKinds.contains(kind))
			handleTry(node, state, ctx);
		else if (kind == BOOL_AND_KIND || kind == BOOL_OR_KIND)
			handleShortCircuit(node, state, ctx);
		else if (ctx.nullCoalKind != null && kind == ctx.nullCoalKind)
			handleNullCoalescing(node, state, ctx);
		else if (ctx.callKind != null && kind == ctx.callKind) {
			for (c in node.children) walk(c, state, ctx);
			handleNullAssertionCall(node, state, ctx);
		} else if (ctx.blockKinds.contains(kind))
			handleBlock(node, state, ctx);
		else
			for (c in node.children) walk(c, state, ctx);
	}

	/** Assignment / compound-assignment / increment: narrow the target to `NonNull` for a plain assign of a non-null value, to `Null` for a plain assign of the null literal, else clear it on both polarities. A `??=` is routed to its own transfer — its right-hand side runs conditionally. */
	private static function handleWrite(node: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		if (node.kind == ctx.nullCoalAssignKind) {
			handleNullCoalAssign(node, state, ctx);
			return;
		}
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
		else if (node.kind == ctx.assignKind && isNullableSourceRhs(rhs, ctx))
			markMaybe(state, name);
		else
			clearName(state, name);
	}

	/**
	 * `x ??= e`: the right-hand side runs only when `x` is null, so its side
	 * effects are joined in — the post-state intersects the RHS-skipped and
	 * RHS-executed paths. The target itself ends `NonNull` when the RHS is
	 * syntactically non-null (whichever side survives, the result is non-null),
	 * else `Unknown`.
	 */
	private static function handleNullCoalAssign(node: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		if (node.children.length == 0) return;
		final target: QueryNode = node.children[0];
		walk(target, state, ctx);
		final rhs: Null<QueryNode> = node.children.length >= 2 ? node.children[1] : null;
		if (rhs != null) {
			final rhsState: FlowState = copyState(state);
			walk(rhs, rhsState, ctx);
			setState(state, intersect(state, rhsState));
		}
		final name: Null<String> = target.name;
		if (target.kind != ctx.identKind || name == null) return;
		if (isNonNullRhs(rhs, ctx))
			markNonNull(state, name);
		else
			clearName(state, name);
	}

	/**
	 * A short-circuit boolean (`a && b` / `a || b`): the right-hand side runs only
	 * when the left one lets it, so its effects are a conditional path. The RHS is
	 * walked on a copy of the running state — narrowed by the LHS the same way an
	 * `if` narrows its arms (`&&` behaves as a then-arm, `||` as an else-arm) — and
	 * the exit state is intersected back (the skip path keeps the pre-RHS facts).
	 */
	private static function handleShortCircuit(node: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		if (node.children.length < 2) {
			for (c in node.children) walk(c, state, ctx);
			return;
		}
		final lhs: QueryNode = node.children[0];
		walk(lhs, state, ctx);
		final isAnd: Bool = node.kind == BOOL_AND_KIND;
		final rhsState: FlowState = isAnd
			? narrowedCopy(lhs, state, ctx, ctx.notEqKind, ctx.eqKind, BOOL_AND_KIND)
			: narrowedCopy(lhs, state, ctx, ctx.eqKind, ctx.notEqKind, BOOL_OR_KIND);
		for (i in 1...node.children.length) walk(node.children[i], rhsState, ctx);
		setState(state, intersect(state, rhsState));
	}

	/**
	 * A null-coalescing `a ?? b`: the fallback runs only when the left side is
	 * null, so its effects are a conditional path — walked on a copy of the
	 * running state and intersected back, like a short-circuit boolean's right
	 * side (no narrowing: the left operand is an arbitrary expression).
	 */
	private static function handleNullCoalescing(node: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		if (node.children.length < 2) {
			for (c in node.children) walk(c, state, ctx);
			return;
		}
		walk(node.children[0], state, ctx);
		final rhsState: FlowState = copyState(state);
		for (i in 1...node.children.length) walk(node.children[i], rhsState, ctx);
		setState(state, intersect(state, rhsState));
	}

	/**
	 * A call to a `nullAssertionCalls` helper (`Assert.notNull(x)`) throws when its plain
	 * identifier argument is null, so after it the argument is non-null. Clears the argument
	 * from `state.maybe` (`maybe`-only — it adds no `NonNull` fact, so the seed-less consumers
	 * are byte-identical), suppressing a `MaybeNull` false positive on a value asserted before
	 * its dereference.
	 */
	private static function handleNullAssertionCall(node: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		if (ctx.fieldAccessKind == null || ctx.nullAssertionCalls.length == 0 || node.children.length < 2) return;
		final callee: QueryNode = node.children[0];
		final method: Null<String> = callee.name;
		if (callee.kind != ctx.fieldAccessKind || method == null || callee.children.length != 1) return;
		final recv: QueryNode = callee.children[0];
		final recvName: Null<String> = recv.name;
		if (recv.kind != ctx.identKind || recvName == null || !ctx.nullAssertionCalls.contains('${recvName}.${method}')) return;
		final arg: QueryNode = node.children[1];
		final argName: Null<String> = arg.name;
		if (arg.kind == ctx.identKind && argName != null) state.maybe.remove(argName);
	}

	/**
	 * Local declaration: set the declared name to `NonNull` for a non-null
	 * initializer, to `Null` for a null-literal initializer, else clear both. A
	 * multi-binding declaration (`var a = 1, b = 2;`) projects as one node whose
	 * name and initializers cannot be attributed to each other — every child is
	 * still walked (their reads and nested writes transfer), but the name's fact
	 * collapses to `Unknown`.
	 */
	private static function handleDecl(node: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		for (c in node.children) walk(c, state, ctx);
		final name: Null<String> = node.name;
		if (name == null) return;
		if (isMultiBinding(node, ctx.source, ctx.declTypeChildKinds)) {
			clearName(state, name);
			return;
		}
		final init: Null<QueryNode> = declInit(node, ctx.declTypeChildKinds);
		if (isNonNullRhs(init, ctx))
			markNonNull(state, name);
		else if (isNullLitRhs(init, ctx))
			markKnown(state, name);
		else if (isNullableSourceRhs(init, ctx))
			markMaybe(state, name);
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
		final thenState: FlowState = narrowedCopy(cond, state, ctx, ctx.notEqKind, ctx.eqKind, BOOL_AND_KIND);
		walk(thenArm, thenState, ctx);
		// An unbraced arm declaration (`if (c) var v = null;`) never passes through
		// `handleBlock`'s exit clearing — drop its facts before the join.
		clearDeclaredIn(thenArm, thenState, ctx);
		// Else path: the negated condition (`!(a || b)` = `!a && !b`), so an `== null`
		// disjunct proves non-null and a `!= null` disjunct proves null.
		final elseState: FlowState = narrowedCopy(cond, state, ctx, ctx.eqKind, ctx.notEqKind, BOOL_OR_KIND);
		if (elseArm != null) {
			walk(elseArm, elseState, ctx);
			clearDeclaredIn(elseArm, elseState, ctx);
		}
		// Join: a fact holds after the `if` only if it holds on every path that falls
		// through to here. An arm that returns / throws contributes no path, so the
		// surviving arm's state passes through unintersected — this gives early-return
		// narrowing (`if (x == null) return;` leaves x non-null after).
		final thenExits: Bool = armExits(thenArm, ctx);
		final elseExits: Bool = elseArm != null && armExits(elseArm, ctx);
		final post: FlowState = if (thenExits && elseExits)
			{ nonNull: [], known: [], maybe: [] };
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

	/** Fire the consumer callback at `node` with the facts holding in `state`. */
	private static function visitNode(node: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		final facts: NullFacts = {
			nonNull: n -> ctx.ownNames.contains(n) && !ctx.captured.contains(n) && state.nonNull.contains(n),
			isNull: n -> ctx.ownNames.contains(n) && !ctx.captured.contains(n) && state.known.contains(n),
			isMaybeNull: n -> ctx.ownNames.contains(n) && !ctx.captured.contains(n) && state.maybe.contains(n)
		};
		ctx.visit(node, facts);
	}

	/**
	 * `switch`: the subject transfers on the running state; each branch is then
	 * analyzed in isolation from the post-subject state — with every identifier in
	 * the case pattern cleared first, because a pattern capture is a fresh binding
	 * shadowing any same-named outer local (clearing a constructor or guard
	 * identifier alongside is only a safe miss). Every name a case GUARD writes is
	 * cleared from the shared post-subject state up front: guards of the branches
	 * before the taken one run during dispatch, so their writes may have happened
	 * on any path. The post-state intersects the exit states of the branches that
	 * fall through; a branch whose last statement exits (`return` / `throw` / a
	 * loop jump) contributes no path. Unless the switch is provably exhaustive — a
	 * `default:` branch or an unguarded wildcard `case _:` — the no-branch-matched
	 * path (the post-subject state itself) joins the intersection.
	 */
	private static function handleSwitch(node: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		final branches: Array<QueryNode> = [];
		var hasDefault: Bool = false;
		var subjectName: Null<String> = null;
		for (c in node.children) {
			if (c.kind == ctx.caseBranchKind) {
				branches.push(c);
				if (isWildcardCase(c, ctx)) hasDefault = true;
			} else if (c.kind == ctx.defaultBranchKind) {
				branches.push(c);
				hasDefault = true;
			} else {
				if (subjectName == null && c.kind == ctx.identKind) subjectName = c.name;
				walk(c, state, ctx);
			}
		}
		for (b in branches) {
			final guard: Null<QueryNode> = caseGuard(b, ctx);
			if (guard != null) killWritten(guard, state, ctx);
		}
		// Once a `case null:` branch consumes the null value, every LATER branch has a
		// plain-identifier subject non-null, and a branch's own `!= null` guard proves its
		// operands non-null in the body. Both narrowings live in `walkBranch` and are
		// `maybe`-only, so the seed-less consumers (the six flow checks) stay byte-identical.
		final exitStates: Array<FlowState> = [];
		var nullConsumed: Bool = false;
		for (b in branches) {
			final exit: Null<FlowState> = walkBranch(b, state, ctx, subjectName, nullConsumed);
			if (exit != null) exitStates.push(exit);
			if (isNullConsumingCase(b, ctx)) nullConsumed = true;
		}
		var post: Null<FlowState> = hasDefault ? null : copyState(state);
		for (e in exitStates) post = post == null ? e : intersect(post, e);
		setState(state, post ?? { nonNull: [], known: [], maybe: [] });
	}

	/**
	 * Analyze one `switch` branch from `state`, returning its exit state — or null if the
	 * branch's last statement exits (contributing no fall-through path). The subject is
	 * narrowed to non-null (`maybe`-only) when `nullConsumed` (an earlier `case null:`
	 * already consumed null), and each `!= null` guard conjunct clears its operand from
	 * `maybe` — both suppress a `MaybeNull` false positive without adding a `NonNull` fact.
	 */
	private static function walkBranch(
		b: QueryNode, state: FlowState, ctx: FlowCtx, subjectName: Null<String>, nullConsumed: Bool
	): Null<FlowState> {
		final branchState: FlowState = copyState(state);
		clearBranchPatterns(b, branchState, ctx);
		if (nullConsumed && subjectName != null) branchState.maybe.remove(subjectName);
		final guard: Null<QueryNode> = caseGuard(b, ctx);
		if (guard != null) clearMaybeByGuard(guard, branchState, ctx);
		visitNode(b, branchState, ctx);
		for (c in b.children) walk(c, branchState, ctx);
		// Exit clearing: the branch body is not block-wrapped, so a shadow's facts must be
		// dropped here (an inner local declaration or a written pattern capture).
		clearDeclaredIn(b, branchState, ctx);
		clearBranchPatterns(b, branchState, ctx);
		final last: Null<QueryNode> = b.children.length > 0 ? b.children[b.children.length - 1] : null;
		return last == null || !armExits(last, ctx) ? branchState : null;
	}

	/**
	 * Clears every name a case branch's patterns mention — the first pattern child
	 * plus every comma alternative (`case a(v), b(v):` projects one leading
	 * `plainCasePatternKind` child per alternative). Pattern idents are fresh
	 * bindings (captures) or enum-constructor names, never runtime reads of an
	 * outer local, so an outer fact must not survive into them.
	 */
	private static function clearBranchPatterns(b: QueryNode, branchState: FlowState, ctx: FlowCtx): Void {
		if (b.kind != ctx.caseBranchKind || b.children.length == 0) return;
		clearPatternNames(b.children[0], branchState, ctx);
		for (c in b.children) if (ctx.plainCasePatternKind != null && c.kind == ctx.plainCasePatternKind)
			clearPatternNames(c, branchState, ctx);
	}

	/**
	 * `try`: the body is analyzed from the entry state. Each catch clause starts
	 * from the entry state with every name the body writes cleared — the throw may
	 * fire at any point inside the body, so no body write may be trusted there —
	 * and with its own catch variable cleared (a fresh binding shadowing any
	 * same-named outer local). The post-state intersects the exit states of the
	 * body and of every clause that falls through; a body or clause ending in an
	 * exit contributes no path.
	 */
	private static function handleTry(node: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		if (node.children.length == 0) return;
		final body: QueryNode = node.children[0];
		final tryState: FlowState = copyState(state);
		walk(body, tryState, ctx);
		final catchEntry: FlowState = copyState(state);
		killWritten(body, catchEntry, ctx);
		final exitStates: Array<FlowState> = [];
		if (!armExits(body, ctx)) exitStates.push(tryState);
		for (i in 1...node.children.length) {
			final clause: QueryNode = node.children[i];
			final clauseState: FlowState = copyState(catchEntry);
			final varName: Null<String> = clause.name;
			final isCatch: Bool = clause.kind == ctx.catchClauseKind;
			if (isCatch && varName != null) clearName(clauseState, varName);
			visitNode(clause, clauseState, ctx);
			for (c in clause.children) walk(c, clauseState, ctx);
			// Exit clearing: a write to the catch variable or to a bare-body shadow
			// declaration must not leak out under the outer binding's name.
			clearDeclaredIn(clause, clauseState, ctx);
			if (isCatch && varName != null) clearName(clauseState, varName);
			final last: Null<QueryNode> = clause.children.length > 0 ? clause.children[clause.children.length - 1] : null;
			if (last == null || !armExits(last, ctx)) exitStates.push(clauseState);
		}
		var post: Null<FlowState> = null;
		for (e in exitStates) post = post == null ? e : intersect(post, e);
		setState(state, post ?? { nonNull: [], known: [], maybe: [] });
	}

	/**
	 * Whether `branch` is an unguarded wildcard case (`case _:`) — its pattern is the
	 * plain wrapper holding just the wildcard identifier, so it matches every subject
	 * and makes the switch exhaustive. A guard keeps the plain pattern wrapper and
	 * projects as a bare parenthesized-expression sibling child before the body
	 * statements — a guarded wildcard can still fail to match, so it never counts.
	 */
	private static function isWildcardCase(branch: QueryNode, ctx: FlowCtx): Bool {
		if (branch.children.length == 0 || ctx.wildcardPatternName == null) return false;
		if (caseGuard(branch, ctx) != null) return false;
		final pattern: QueryNode = branch.children[0];
		if (pattern.kind != ctx.plainCasePatternKind || pattern.children.length != 1) return false;
		final ident: QueryNode = pattern.children[0];
		return ident.kind == ctx.identKind && ident.name == ctx.wildcardPatternName;
	}

	/**
	 * The guard expression of a case branch (`case p if (c):` — a bare parenthesized
	 * expression between the pattern alternatives and the body), or null when
	 * unguarded. Scans past the leading pattern children so a comma-alternative form
	 * (`case _, 4 if (c):`) is caught too; an expression-switch arm value that
	 * happens to be parenthesized may be mistaken for a guard, which only errs
	 * conservative (a non-exhaustive verdict / an extra write kill).
	 */
	private static function caseGuard(branch: QueryNode, ctx: FlowCtx): Null<QueryNode> {
		if (ctx.parenKind == null) return null;
		for (i in 1...branch.children.length) if (branch.children[i].kind == ctx.parenKind) return branch.children[i];
		return null;
	}

	/**
	 * Clear from `state.maybe` every name a case guard proves non-null (its `!= null`
	 * conjuncts). `maybe`-only: it adds no `NonNull` fact, so a seed-less consumer is
	 * unaffected; the narrowing exists solely to suppress a `MaybeNull` false positive in
	 * a `case _ if (u != null):` body.
	 */
	private static function clearMaybeByGuard(guard: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		final names: Array<String> = [];
		collectNarrow(guard, names, ctx, ctx.notEqKind, BOOL_AND_KIND);
		for (n in names) state.maybe.remove(n);
	}

	/**
	 * Whether `b` is an unguarded case whose pattern matches the null literal
	 * (`case null:` / `case null, x:`) — so it consumes the null value and every LATER
	 * branch sees a plain-identifier subject non-null. A guard could fail to match, so a
	 * guarded null case does not count (conservative).
	 */
	private static function isNullConsumingCase(b: QueryNode, ctx: FlowCtx): Bool {
		final nl: Null<String> = ctx.nullLitKind;
		if (b.kind != ctx.caseBranchKind || nl == null || caseGuard(b, ctx) != null) return false;
		for (c in b.children) if (ctx.plainCasePatternKind != null && c.kind == ctx.plainCasePatternKind) for (p in c.children) if (
			p.kind == nl
		)
			return true;
		return false;
	}

	/** Clear every identifier name in a case-pattern subtree from `state` — a pattern capture is a fresh binding shadowing any same-named outer local, so no outer fact may survive into the branch. */
	private static function clearPatternNames(pattern: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		final name: Null<String> = pattern.name;
		if (pattern.kind == ctx.identKind && name != null) clearName(state, name);
		for (c in pattern.children) clearPatternNames(c, state, ctx);
	}

	/**
	 * Clear from `state` every fact for a name locally declared anywhere in `scope`.
	 * A construct whose body is not block-wrapped (a case body, an unbraced `if`
	 * arm, a bare catch body) never passes through `handleBlock`'s exit clearing,
	 * so an inner declaration's fact would otherwise leak out of the construct
	 * under the outer binding's name — a false fact, since the outer binding's
	 * runtime value is untouched by writes to the shadow.
	 */
	private static function clearDeclaredIn(scope: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		for (n in collectDeclared(scope, ctx.localDeclKinds)) clearName(state, n);
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

	/** Whether `rhs` is a nullable source per the consumer's seed predicate (mechanism A) — always false when no seed was supplied, so the flow checks never see a `MaybeNull` fact. */
	private static function isNullableSourceRhs(rhs: Null<QueryNode>, ctx: FlowCtx): Bool {
		final seed: Null<(QueryNode) -> Bool> = ctx.nullableSourceRhs;
		return rhs != null && seed != null && seed(rhs);
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

	/**
	 * Names assigned anywhere inside `node`'s subtree — the write-target idents of
	 * every `writeKinds` node. The collect-only sibling of `killWritten`.
	 */
	private static function collectWrites(node: QueryNode, out: Array<String>, ctx: FlowCtx): Void {
		if (ctx.writeKinds.contains(node.kind) && node.children.length >= 1) {
			final target: QueryNode = node.children[0];
			final name: Null<String> = target.name;
			if (target.kind == ctx.identKind && name != null && !out.contains(name)) out.push(name);
		}
		for (c in node.children) collectWrites(c, out, ctx);
	}

	/**
	 * A copy of `base` narrowed by `cond`'s null comparisons for one outcome
	 * polarity: `cmpNonNull`-kind comparisons (combined over `combineKind`) prove
	 * their operand non-null, `cmpKnown`-kind ones prove it null. A name the
	 * condition itself writes is excluded from both — its comparison may predate
	 * the write, so that narrowing would be stale (the write's own effect already
	 * reached `base` when the condition was walked).
	 */
	private static function narrowedCopy(
		cond: QueryNode, base: FlowState, ctx: FlowCtx, cmpNonNull: Null<String>, cmpKnown: Null<String>, combineKind: String
	): FlowState {
		final out: FlowState = copyState(base);
		final written: Array<String> = [];
		collectWrites(cond, written, ctx);
		final nonNull: Array<String> = [];
		collectNarrow(cond, nonNull, ctx, cmpNonNull, combineKind);
		for (n in nonNull) if (!written.contains(n)) markNonNull(out, n);
		final known: Array<String> = [];
		collectNarrow(cond, known, ctx, cmpKnown, combineKind);
		for (n in known) if (!written.contains(n)) markKnown(out, n);
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

	/** Record `name` as `NonNull` in `state`, clearing any `Null` / `MaybeNull` fact (the three sets stay disjoint), deduplicated. */
	private static inline function markNonNull(state: FlowState, name: String): Void {
		if (!state.nonNull.contains(name)) state.nonNull.push(name);
		state.known.remove(name);
		state.maybe.remove(name);
	}

	/** Record `name` as `Null` in `state`, clearing any `NonNull` / `MaybeNull` fact (the three sets stay disjoint), deduplicated. */
	private static inline function markKnown(state: FlowState, name: String): Void {
		if (!state.known.contains(name)) state.known.push(name);
		state.nonNull.remove(name);
		state.maybe.remove(name);
	}

	/** Record `name` as `MaybeNull` in `state` — a value from a nullable source, pending a narrowing — clearing any `NonNull` / `Null` fact (the three sets stay disjoint), deduplicated. */
	private static inline function markMaybe(state: FlowState, name: String): Void {
		if (!state.maybe.contains(name)) state.maybe.push(name);
		state.nonNull.remove(name);
		state.known.remove(name);
	}

	/** Drop every fact about `name` — it becomes `Unknown`. */
	private static inline function clearName(state: FlowState, name: String): Void {
		state.nonNull.remove(name);
		state.known.remove(name);
		state.maybe.remove(name);
	}

	/** A deep copy of `state` — an isolated branch state the caller can mutate without affecting the original. */
	private static inline function copyState(state: FlowState): FlowState {
		return { nonNull: state.nonNull.copy(), known: state.known.copy(), maybe: state.maybe.copy() };
	}

	/**
	 * Whether `arm` definitely transfers control out instead of falling through to the
	 * statement after the enclosing construct — a `return` / `throw`
	 * (`RefShape.controlExitKinds`), a loop jump (`break` / `continue` project as plain
	 * identifiers named so, bare or wrapped in an expression statement), or a block whose
	 * last statement does. Conservative: anything it cannot prove exits is treated as
	 * falling through, which only ever loses precision in the join, never soundness. A
	 * loop jump is a sound exit for every join it participates in: the jumped-to point is
	 * past the enclosing construct, and the state it carries never feeds a post-loop
	 * state (a loop's post-state is its entry with every loop-written name cleared).
	 */
	private static function armExits(arm: QueryNode, ctx: FlowCtx): Bool {
		if (ctx.controlExitKinds.contains(arm.kind)) return true;
		if (isLoopJump(arm, ctx)) return true;
		if (arm.kind == ctx.exprStmtKind && arm.children.length == 1 && isLoopJump(arm.children[0], ctx)) return true;
		if (ctx.blockKinds.contains(arm.kind) && arm.children.length > 0) return armExits(arm.children[arm.children.length - 1], ctx);
		return false;
	}

	/** Whether `node` is a bare loop-jump identifier (`break` / `continue` — `RefShape.loopJumpNames`). */
	private static function isLoopJump(node: QueryNode, ctx: FlowCtx): Bool {
		final name: Null<String> = node.name;
		return node.kind == ctx.identKind && name != null && ctx.loopJumpNames.contains(name);
	}

	/** The facts holding on both `a` and `b` — a name keeps a polarity after a join only if it held it on both arms. */
	private static function intersect(a: FlowState, b: FlowState): FlowState {
		return {
			nonNull: [for (n in a.nonNull) if (b.nonNull.contains(n)) n],
			known: [for (n in a.known) if (b.known.contains(n)) n],
			maybe: [for (n in a.maybe) if (b.maybe.contains(n)) n]
		};
	}

	/** Replace the contents of `state` in place with `next` (the running state is mutated for the caller). */
	private static inline function setState(state: FlowState, next: FlowState): Void {
		state.nonNull.resize(0);
		for (n in next.nonNull) state.nonNull.push(n);
		state.known.resize(0);
		for (n in next.known) state.known.push(n);
		state.maybe.resize(0);
		for (n in next.maybe) state.maybe.push(n);
	}

	/** Whether `source[from..to)` contains a comma outside every bracket pair and string literal. */
	private static function hasTopLevelComma(source: String, from: Int, to: Int): Bool {
		var depth: Int = 0;
		var quote: Int = 0;
		var i: Int = from;
		final end: Int = to <= source.length ? to : source.length;
		while (i < end) {
			final c: Int = StringTools.fastCodeAt(source, i);
			if (quote != 0) {
				if (c == '\\'.code)
					i++;
				else if (c == quote)
					quote = 0;
			} else if (c == "'".code || c == '"'.code) {
				quote = c;
			} else if (c == '('.code || c == '['.code || c == '{'.code) {
				depth++;
			} else if (c == ')'.code || c == ']'.code || c == '}'.code) {
				depth--;
			} else if (c == ','.code && depth == 0) {
				return true;
			}
			i++;
		}
		return false;
	}

}

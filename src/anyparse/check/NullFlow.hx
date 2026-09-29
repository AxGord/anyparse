package anyparse.check;

import anyparse.query.BinderScan;
import anyparse.query.BoolExprShape;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.MemberKinds;
import anyparse.query.NodeShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.SourceText;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * The null facts holding at one visited node's entry, queried by a consumer.
 * `nonNull(name)` answers whether `name` is provably non-null by flow there;
 * `isNull(name)` whether it is provably null; `isMaybeNull(name)` whether it came from a nullable source and is not yet
 * narrowed non-null (a mechanism-A seed, empty for the flow checks that pass none). All three honour the closure-captured
 * exclusion. At most one of the three accessors is ever true for a given name (`NonNull`, `Null`, `MaybeNull`, or — none true — `Unknown`).
 *
 * `indexPresent(node)` is the one name-free accessor: it answers whether `node` is a map
 * read `m[k]` whose (map, key) pair a dominating `m.exists(k)` guard proves present here.
 * It reports the same `present` fact the `MaybeNull` seed consults, so the point-wise
 * `possible-null-dereference` and the flow-sensitive `unguarded-nullable-deref` read ONE
 * exists-guard model rather than two.
 */
typedef NullFacts = {
	var nonNull: String -> Bool;

	/**
	 * Whether `name` is `NonNull` by flow through forms the compiler's null-safety is probed to follow, and only those:
	 * a direct `!= null` / `== null` of the name narrowing its own `if` / `while` / `&&` / `||`, an early exit or a
	 * non-null assignment in the same statement sequence, and a join of live arms that are each visible. Everything else
	 * is unseen — a Bool local, an alias, a `?.` comparison, what the body of a lone surviving `if` arm or `switch` branch
	 * proved, what a `try` proved, and any construct `ownsVisibility` does not name.
	 */
	var nonNullVisible: String -> Bool;
	var isNull: String -> Bool;
	var isMaybeNull: String -> Bool;
	var indexPresent: QueryNode -> Bool;
}

/**
 * The per-path fact lattice carried through a `NullFlow` walk: the set of names
 * provably `NonNull` and the disjoint set provably `Null` at the current point.
 * A name in the third `maybe` set is `MaybeNull`; a name absent from all three is `Unknown`.
 * Every transfer keeps the three sets pairwise disjoint (marking one polarity clears the others).
 */
private typedef FlowState = {
	var nonNull: Array<String>;

	/** The `nonNull` names some path proves only through a narrowing the compiler cannot see (see `NullFacts.nonNullVisible`). */
	var unseen: Array<String>;
	var known: Array<String>;
	var maybe: Array<String>;
	var predicates: Array<PredicateFact>;
	var aliases: Array<AliasPair>;
	var present: Array<ExistsFact>;
}

/**
 * A laundered-guard fact: `bool ⇒ (target != null)` when `notEq`, else `bool ⇒ (target == null)`. A Bool
 * own-name local bound to a null-comparison of a plain own-name ident, so branching on `bool` narrows `target`.
 * `compound` marks a one-way fact seeded from a conjunctive RHS (`bool = a != null && …`): only its truth (the
 * then-arm) narrows each conjunct, its falsity implying no single one — so the else-arm mirror is suppressed.
 */
private typedef PredicateFact = {
	bool: String,
	target: String,
	notEq: Bool,
	compound: Bool
};

/**
 * An unordered pair of plain own-name locals proven to hold the same reference (a direct `v
 * = u` copy) — narrowing either narrows both, until one is written, captured, or re-aliased.
 */
private typedef AliasPair = { a: String, b: String };

/**
 * A map/key pair proven present by a dominating `m.exists(k)` guard: the two operand expressions by their verbatim source
 * text, plus `names` — every identifier either of them mentions, so any write to one kills the fact. Both operands must be
 * PURE REF PATHS (identifier, field access, index access, a leaf literal), never a call: text identity plus the write-kill
 * is the whole soundness argument, and a call could answer a different map on the second evaluation. A same-map/key `m[k]` read
 * under the guard is not seeded `MaybeNull`, and `NullFacts.indexPresent` reports it to the point-wise consumer. A `value` fact
 * is the same pair proven by the ENTRY rather than by `exists`: a `m[k] != null` guard, or a write of a non-null value to
 * `m[k]`. Since a call or a write through a path can change an entry without writing either name, every call, `new`, non-name
 * write and loop entry kills the value facts, so a value fact holds only for a re-read with nothing but name reads between.
 */
private typedef ExistsFact = {
	map: String,
	key: String,
	names: Array<String>,
	value: Bool
};

/**
 * A function whose truth proves some of its arguments non-null: its body is one `return` of a
 * conjunction holding `param != null` for each of `nonNullParams` (indices into its `arity`
 * parameters), with each parameter's written type (`paramTypes`, whitespace-stripped, null when
 * unwritten). `body` is the span of the type body declaring it — a bare call to `name` binds to
 * it only from inside that span.
 */
private typedef NonNullPredicate = {
	name: String,
	body: Span,
	arity: Int,
	nonNullParams: Array<Int>,
	paramTypes: Array<Null<String>>
};

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
	var notKind: Null<String>;
	var writeKinds: Array<String>;
	var localDeclKinds: Array<String>;
	var declTypeChildKinds: Array<String>;
	var localDeclContinuationKinds: Array<String>;
	var ifKinds: Array<String>;
	var loopKinds: Array<String>;
	var preTestLoopKinds: Array<String>;
	var switchKinds: Array<String>;
	var tryKinds: Array<String>;
	var blockKinds: Array<String>;
	var controlExitKinds: Array<String>;
	var nonNullRhsKinds: Array<String>;
	var opaqueKinds: Array<String>;

	/**
	 * The nested function-value kinds — a separate flow context: their bodies are not walked with
	 * the outer state, and the names they touch are excluded from the enclosing unit's analysis.
	 *
	 * `RefactorSupport.nestedFunctionKinds(shape)` and nothing else. It must cover EVERY spelling
	 * of a function value the grammar projects, or the omitted one is analyzed as straight-line
	 * code belonging to the enclosing function: a hand-written list missing `ThinArrow` — the
	 * bare `v -> …` — makes `dead-store` report a false positive on any local a bare-arrow
	 * callback writes, because the lambda's own `return` clears the backward liveness state.
	 * Reading the derived authority is what keeps a grammar that adds a spelling from re-opening
	 * that hole in silence.
	 */
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
	var newExprKind: Null<String>;

	/** The file's non-null predicate functions (`nonNullPredicates`), which a positive call to narrows its arguments. */
	var nonNullPredicates: Array<NonNullPredicate>;

	/** The written type of the binding an argument identifier resolves to, whitespace-stripped, or null. */
	var argType: QueryNode -> Null<String>;
	var fieldAccessKind: Null<String>;
	var nullSafeAccessKind: Null<String>;
	var indexAccessKind: Null<String>;
	var nullAssertionCalls: Array<String>;
	var assertTrueCalls: Array<String>;
	var assertFalseCalls: Array<String>;
	var mapExistsMethods: Array<String>;
	var captured: Array<String>;

	/** `RefShape.selfScopeDeclKinds`: constructs whose own name binds into the scope they open (`for`, `catch`). */
	var selfScopeDeclKinds: Array<String>;

	/** `BinderScan.binderKinds`: every node kind the grammar projects as a named binder. */
	var binderKinds: Array<String>;
	var ownNames: Array<String>;
	var source: String;
	var nullableSourceRhs: Null<QueryNode -> Bool>;

	/**
	 * Whether a local `var` / `final` DECLARATION carries an explicitly nullable written
	 * annotation. Asked only where the initializer gives the expression seed no opinion, so a
	 * nullable source the walk has already ruled present is never re-seeded through the
	 * annotation. Parameters are never asked (see `analyze`). Null for the consumers that pass none.
	 */
	var declaredNullable: Null<QueryNode -> Bool>;
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
 * The lattice is four-valued per name: `NonNull`, `Null`, `MaybeNull` (a value from a nullable
 * source, pending a narrowing — populated only when a consumer supplies the mechanism-A seed), or
 * `Unknown`. A name is `NonNull`-by-flow at a point when it is non-null on **every** path reaching
 * it, and `Null`-by-flow when it is null on every such path — each established
 * only by a flow event: a guard narrowing a branch (a `!= null` then-arm / `== null`
 * else-arm proves non-null; the mirror proves null), or an assignment of a
 * syntactically definite value (`new T(...)` / a non-null literal is non-null,
 * the `null` literal is null; a `??=` of a non-null value leaves the target
 * non-null whichever side survives, and its right-hand side's effects are
 * joined in as conditional). It seeds **no** facts from declared types —
 * declared-non-null is the point-wise checks' domain (`TypeResolver.isProvablyNonNull`); this
 * engine is strictly the flow-only complement, so a flow consumer never duplicates a point-wise
 * finding. The one exception is the optional `MaybeNull` seed (mechanism A): when a consumer
 * supplies a `seed` predicate, a local assigned a value the predicate accepts (a nullable source)
 * becomes `MaybeNull` until narrowed, backing the flow-sensitive `unguarded-nullable-deref` —
 * inert for every consumer that passes no seed.
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
 *   and intersects the exit back, so a write inside the RHS never leaks a fact onto the skip
 *   path; a plain `??` fallback gets the same conditional join. Narrowing from a condition
 *   never keeps a fact for a name the condition itself writes — that comparison may predate
 *   the write.
 * - **Closures.** A name mutated inside any nested function value is excluded
 *   from both polarities for the whole function (a closure call could reassign it).
 *   The value's own body is not skipped, only separated: it is ANALYZED, as a unit
 *   of its own with its own names (`forEachFunctionUnit`), so a fact established
 *   inside a callback is never carried out of it and one established outside is
 *   never carried in.
 * - **Opaque subtrees.** Macro-reification (`RefShape.opaqueKinds`) is not descended into, and
 *   metadata annotations (`META_KINDS`) are skipped entirely — their arguments are compile-time
 *   data, never runtime code.
 * - **Auxiliary facts (laundered predicates, aliases, exists-guards).** A Bool
 *   local bound EXACTLY to a null-comparison of a plain own-name ident records a
 *   predicate (`ok => u != null`), so branching on it narrows the compared name
 *   (De Morgan mirror in the else-arm); a direct plain ident-to-ident copy
 *   (`var v = u`) records a bidirectional alias, so narrowing one side narrows
 *   the other; an `m.exists(k)` test marks the pair present on
 *   the branch it holds — the then-arm of a positive test, the else-arm (and so the
 *   fall-through of `if (!m.exists(k)) return;`) of a negated one, and either side of a
 *   short-circuit whose left operand is one — so a `var u = m[k]` there is not seeded
 *   `MaybeNull` and `NullFacts.indexPresent` reports the same pair to the point-wise check.
 *   Operands are PURE REF PATHS compared by source text (`a.b.map`, `outer[i]`), never
 *   calls. Every fact dies on ANY write to a name it mentions (including
 *   `??=`, whose target may be reassigned), on capture (never established for a
 *   closure-mutated name), at shadow entry/exit, and at any join where it does
 *   not hold on both arms. A conjunctive Bool RHS (`ok = a != null && …`, with no `||`
 *   anywhere) seeds a one-way `compound` predicate per null-comparison conjunct — narrowing
 *   only in the then-arm; a Bool-to-Bool copy (`var ok2 = ok`) aliases the two, so a predicate
 *   launders transitively through the alias closure; and a `!(…)` guard flips both the
 *   comparison polarity and the combine operator (De Morgan), unwinding nested negations.
 *   Anything else — a field or call RHS, or any `||` inside an otherwise-conjunctive RHS —
 *   establishes nothing (a refusal is only a safe miss).
 *
 * Pure, stateless class (mirrors `TypeResolver`).
 */
@:nullSafety(Strict)
final class NullFlow {

	/** Branch constructs with two mutually-exclusive value arms — analyzed with isolated branch states. */
	public static final IF_KINDS: Array<String> = ['IfStmt', 'IfExpr', 'Ternary'];

	/** Loop constructs — every name they assign is cleared before the body so a back-edge carries no stale fact. */
	public static final LOOP_KINDS: Array<String> = ['WhileStmt', 'DoWhileStmt', 'ForStmt', 'WhileExpr', 'ForExpr'];

	/**
	 * The PRE-TEST loops among `LOOP_KINDS` — children `[condition, body …]`, the condition
	 * evaluated before every iteration, so it narrows the body exactly as an `if` narrows its
	 * then-arm (`while (x != null) { … }` leaves `x` non-null inside). A `DoWhileStmt` is
	 * deliberately absent: its body runs BEFORE the test, so the condition proves nothing there.
	 * A `for` has no null test to read.
	 */
	public static final PRE_TEST_LOOP_KINDS: Array<String> = ['WhileStmt', 'WhileExpr'];

	/**
	 * `switch` construct kinds — joined branch-per-branch by the flow walk
	 * (statement and expression forms, bare and parenthesized subjects).
	 */
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

	/**
	 * Expression kinds whose value can never be null — a safe non-null assignment RHS.
	 *
	 * Also read by `NullableSource.initTypeIsNonNull`, which asks the same question of a
	 * ternary's value arms one level down: a chain resolver types a call but says nothing
	 * about a bare literal, and a literal arm is exactly what this list already answers.
	 */
	public static final NON_NULL_RHS_KINDS: Array<String> = [
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

	/** The array-literal node kind — its elements evaluate in order, so it keeps what they prove. */
	private static final ARRAY_KIND: String = 'ArrayExpr';

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

	/**
	 * Walk every function unit in `root` (`RefShape.functionKinds`) in flow
	 * order, calling `visit(node, facts)` pre-order at each node, where `facts`
	 * answers whether a name is provably non-null (`facts.nonNull`) or provably
	 * null (`facts.isNull`) by flow at that node's entry. `source` is the file's
	 * verbatim text (multi-binding declarations are detected textually). A
	 * consumer inspects only the node kinds it cares about. A grammar lacking the
	 * required shape fields makes this a no-op.
	 *
	 * `seed` recognises a nullable-source EXPRESSION (a `MaybeNull` initializer / right-hand side);
	 * `declaredNullable` recognises a nullable LOCAL DECLARATION — one whose written annotation is
	 * `Null<T>` — and seeds `MaybeNull` at the binding, so a local no nullable expression feeds still
	 * carries the fact. The two are disjoint by construction: `declaredNullable` is consulted only
	 * where `seed` has no opinion about the initializer, which is what keeps a `m.exists(k)`-proven
	 * map read from being re-seeded through its annotation.
	 *
	 * PARAMETERS are deliberately NOT seeded from their annotation, for the reason
	 * `nullableFlowExcludedCalls` exists: a parameter's nullability is a contract with CALLERS, and
	 * this walk is caller-blind, so the dominant idiom — a `Null<T>` argument valid under a mode a
	 * companion argument establishes (`f(subdivide: Bool, info: Null<Info>)`) — is safe by a
	 * relational invariant no name-keyed flow can model; seeding parameters adds almost nothing but
	 * that shape.
	 */
	public static function analyze(
		root: QueryNode, shape: RefShape, source: String, visit: (QueryNode, NullFacts) -> Void, ?seed: (QueryNode) -> Bool,
		?declaredNullable: (QueryNode) -> Bool, ?typeSources: Map<Int, String>
	): Void {
		final identKind: Null<String> = shape.identKind;
		if (identKind == null) return;
		final id: String = identKind;
		final predicates: Array<NonNullPredicate> = typeSources == null ? [] : nonNullPredicates(root, shape, id, typeSources);
		final written: Map<Int, String> = typeSources ?? [];
		final argType: QueryNode -> Null<String> = arg -> TypeResolver.identDeclaredTypeSource(arg, shape, root, () -> written, false);
		forEachFunctionUnit(
			root, shape,
			(body, paramNames) -> analyzeBody(body, shape, source, id, paramNames, visit, seed, declaredNullable, predicates, argType)
		);
	}

	/**
	 * The file's NON-NULL PREDICATES: member functions whose truth proves an argument non-null, so a
	 * guard `if (!check(item)) return;` narrows `item` like `if (item == null) return;` would. A
	 * positive whitelist, every clause of which a call site must be able to rely on:
	 *
	 *  - the body is ONE `return` of a conjunction (`&&`, parentheses unwrapped) with a
	 *    `param != null` conjunct, and writes nothing — so a true result means the argument passed
	 *    was not null;
	 *  - the member cannot be replaced: `inline`, `static` or `final`, and not `dynamic`, `macro`,
	 *    `overload` or `@:overload` — a subclass override or a reassigned body would answer instead;
	 *  - no rest parameter, and its name is declared nowhere else in the file (no local, parameter,
	 *    capture or second member of that name), so a bare call inside the declaring type body can
	 *    only bind to it.
	 *
	 * Anything else is not a predicate. A call must be bare, pass exactly `arity` arguments, and sit inside the
	 * declaring type body, and an argument counts only when its binding is written with the SAME type text as the
	 * parameter (`predicateArgs`): a different type may reach the parameter through an implicit conversion (an
	 * abstract's `@:from` / `@:to`) that turns a null argument into a non-null parameter. The written types come
	 * from `TypeInfoProvider.declaredTypeSources`, so a consumer passing none to `analyze` gets no predicates at all.
	 */
	private static function nonNullPredicates(
		root: QueryNode, shape: RefShape, identKind: String, typeSources: Map<Int, String>
	): Array<NonNullPredicate> {
		final maybeNotEq: Null<String> = shape.notEqKind;
		if (maybeNotEq == null) return [];
		final notEqKind: String = maybeNotEq;
		final fnKinds: Array<String> = (
			shape.functionKinds ?? []
		).concat(shape.finalModifierMemberKind == null ? [] : [shape.finalModifierMemberKind]);
		final declKinds: Array<String> = BinderScan.binderKinds(shape).concat(fnKinds).concat(shape.fieldDeclKinds ?? []);
		final modifierKinds: Array<String> = (shape.visibilityModifierKinds ?? []).concat(shape.modifierOrderKinds ?? [])
			.concat(META_KINDS);
		final declared: Map<String, Int> = [];
		function count(node: QueryNode): Void {
			final name: Null<String> = node.name;
			if (name != null && declKinds.contains(node.kind)) declared[name] = (declared[name] ?? 0) + 1;
			for (c in node.children) count(c);
		}
		count(root);
		final out: Array<NonNullPredicate> = [];
		function walk(node: QueryNode): Void {
			final decl: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			final bodySpan: Null<Span> = decl?.nameNode.span;
			if (decl != null && bodySpan != null) for (fn in decl.nameNode.children) {
				final name: Null<String> = fn.name;
				if (name == null || !fnKinds.contains(fn.kind) || declared[name] != 1) continue;
				final modifiers: Array<QueryNode> = MemberKinds.precedingModifiers(fn, decl.nameNode, modifierKinds).concat(fn.children);
				final predicate: Null<NonNullPredicate> = predicateOf(
					fn, name, bodySpan, modifiers, shape, identKind, notEqKind, typeSources
				);
				if (predicate != null) out.push(predicate);
			}
			for (c in node.children) walk(c);
		}
		walk(root);
		return out;
	}

	/** `fn` as a `NonNullPredicate` under `nonNullPredicates`' whitelist, given its modifier run `modifiers`, else null. */
	private static function predicateOf(
		fn: QueryNode, name: String, bodySpan: Span, modifiers: Array<QueryNode>, shape: RefShape, identKind: String, notEqKind: String,
		typeSources: Map<Int, String>
	): Null<NonNullPredicate> {
		inline function carries(kind: Null<String>): Bool return kind != null && modifiers.exists(m -> m.kind == kind);
		final overloadMeta: Null<String> = shape.signatureOverloadMetaName;
		if (
			carries(shape.dynamicModifierKind) || carries(shape.macroModifierKind) || carries(shape.overloadModifierKind)
			|| overloadMeta != null && modifiers.exists(m -> META_KINDS.contains(m.kind) && m.name == overloadMeta)
		)
			return null;
		if (fn.kind != shape.finalModifierMemberKind && !carries(shape.inlineModifierKind) && !carries(shape.staticModifierKind))
			return null;
		final params: Array<QueryNode> = fn.children.filter(c -> (shape.paramKinds ?? []).contains(c.kind));
		if (params.exists(p -> p.kind == shape.restParamKind)) return null;
		final returned: Null<QueryNode> = soleReturnedExpr(fn, shape);
		if (returned == null || (shape.writeParentKinds ?? []).exists(k -> MemberKinds.subtreeContainsKind(returned, k))) return null;
		final conjuncts: Array<QueryNode> = [];
		function flatten(n: QueryNode): Void {
			if (n.kind == BOOL_AND_KIND || n.kind == shape.parenKind && n.children.length == 1)
				for (c in n.children) flatten(c)
			else
				conjuncts.push(n);
		}
		flatten(returned);
		final nonNullParams: Array<Int> = [];
		for (c in conjuncts) if (c.kind == notEqKind) {
			final operand: Null<String> = nullComparisonOperand(c, identKind, shape.nullLiteralKind)?.name;
			final index: Int = params.findIndex(p -> p.name == operand);
			if (operand != null && index >= 0 && !nonNullParams.contains(index)) nonNullParams.push(index);
		}
		final paramTypes: Array<Null<String>> = [
			for (p in params) {
				final span: Null<Span> = p.span;
				final written: Null<String> = span == null ? null : typeSources[span.from];
				written == null ? null : TypeResolver.stripWs(written);
			}
		];
		return nonNullParams.length == 0 ? null : {
			name: name,
			body: bodySpan,
			arity: params.length,
			nonNullParams: nonNullParams,
			paramTypes: paramTypes
		};
	}

	/**
	 * The expression `fn` returns when its whole body is one value `return` — a block holding only
	 * that statement, or an expression body — else null.
	 */
	private static function soleReturnedExpr(fn: QueryNode, shape: RefShape): Null<QueryNode> {
		final bodies: Array<QueryNode> = fn.children.filter(c -> (shape.functionBodyKinds ?? []).contains(c.kind));
		if (bodies.length != 1) return null;
		final body: QueryNode = bodies[0];
		final wrapped: Bool = body.kind == shape.blockBodyKind || (shape.expressionBodyKinds ?? []).contains(body.kind);
		if (!wrapped || body.children.length != 1) return null;
		final ret: QueryNode = body.children[0];
		return (shape.valueReturnKinds ?? []).contains(ret.kind) && ret.children.length == 1 ? ret.children[0] : null;
	}

	/**
	 * The argument names a positive call `call` to a `NonNullPredicate` proves non-null: a bare callee
	 * naming one whose type body holds the call, exactly `arity` arguments, and each proven argument a
	 * plain identifier. Empty for any other call.
	 */
	private static function predicateArgs(call: QueryNode, ctx: FlowCtx): Array<String> {
		final span: Null<Span> = call.span;
		if (span == null || call.children.length == 0 || call.children[0].kind != ctx.identKind) return [];
		final callee: Null<String> = call.children[0].name;
		final predicate: Null<NonNullPredicate> = ctx.nonNullPredicates.find(
			p -> p.name == callee && p.body.from <= span.from && span.to <= p.body.to && p.arity == call.children.length - 1
		);
		if (predicate == null) return [];
		final out: Array<String> = [];
		for (i in predicate.nonNullParams) {
			final arg: QueryNode = call.children[i + 1];
			final name: Null<String> = arg.name;
			final written: Null<String> = predicate.paramTypes[i];
			if (arg.kind == ctx.identKind && name != null && written != null && ctx.argType(arg) == written) out.push(name);
		}
		return out;
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
	public static function collectDeclared(node: QueryNode, localDeclKinds: Array<String>, nestedFnKinds: Array<String>): Array<String> {
		final out: Array<String> = [];
		function walkDecl(n: QueryNode): Void {
			if (nestedFnKinds.contains(n.kind)) return;
			final name: Null<String> = n.name;
			if (localDeclKinds.contains(n.kind) && name != null) out.push(name);
			for (c in n.children) walkDecl(c);
		}
		walkDecl(node);
		return out;
	}

	/**
	 * Enumerate every function unit in `root`, calling `each(body, paramNames)` with the unit's body
	 * node and its parameter names. The shared unit-discovery walk of the flow engines (`NullFlow`
	 * and the `dead-store` liveness walk).
	 *
	 * A unit is a function DECLARATION (`RefShape.functionKinds`) or a function VALUE
	 * (`RefactorSupport.nestedFunctionKinds` — every lambda spelling, the named literal, the local
	 * `inline function`). Both halves are needed and neither is optional: the engines already REFUSE
	 * to walk a function value with the enclosing unit's state (it may run at any later time), so a
	 * spelling that is in neither set is analyzed by NOBODY: without the value kinds `dead-store`
	 * reports the dead initializer in `function nm(v) { var z = …; z = …; }` and at top level, and
	 * is silent on the identical body written `v -> { … }` or `function(v) { … }`, and the same
	 * silence covers every flow check, whose consumers then never fire inside any lambda at all.
	 *
	 * Finding the BODY takes two rules because a lambda need not carry a body MARKER. `function(v)`
	 * projects one (`BlockBody` / `ExprBody`, both in `RefShape.functionBodyKinds`) and is found by
	 * kind; an arrow lambda projects its body bare — `v -> v + 1` is `ThinArrow(Required v, Add)`,
	 * `v -> { … }` is `ThinArrow(Required v, BlockExpr)` — so for a function VALUE with no marker
	 * child the body is the LAST child, provided it is not a
	 * parameter or a type annotation. That proviso is a grammar-agnostic guard, not a measured gate:
	 * no Haxe input reaches it — an arrow lambda always ends in its body, and every spelling that can
	 * carry a return-type hint also carries a body marker the kind test finds first — and no test
	 * flips it. It stands because this walk reads `RefShape` for any grammar, and one whose function
	 * value can be signature-only would otherwise be handed a PARAMETER node as a body.
	 *
	 * A unit reports only its OWN names, so a captured outer local written inside a lambda stays
	 * unreportable in both directions: it is not an own name of the lambda unit, and the enclosing
	 * unit excludes every name the lambda touches.
	 */
	public static function forEachFunctionUnit(root: QueryNode, shape: RefShape, each: (QueryNode, Array<String>) -> Void): Void {
		final functionKinds: Array<String> = shape.functionKinds ?? [];
		final bodyKinds: Array<String> = shape.functionBodyKinds ?? [];
		if (functionKinds.length == 0 || bodyKinds.length == 0) return;
		final paramKinds: Array<String> = shape.paramKinds ?? [];
		final typeChildKinds: Array<String> = shape.typeAnnotationKinds ?? [];
		final valueKinds: Array<String> = MemberKinds.nestedFunctionKinds(shape);
		function unitBody(node: QueryNode): Null<QueryNode> {
			final wrapped: Null<QueryNode> = node.children.find(c -> bodyKinds.contains(c.kind));
			if (wrapped != null) return wrapped;
			if (!valueKinds.contains(node.kind) || node.children.length == 0) return null;
			final last: QueryNode = node.children[node.children.length - 1];
			return paramKinds.contains(last.kind) || typeChildKinds.contains(last.kind) ? null : last;
		}
		function findFns(node: QueryNode): Void {
			if (functionKinds.contains(node.kind) || valueKinds.contains(node.kind)) {
				final body: Null<QueryNode> = unitBody(node);
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
	public static function isMultiBinding(node: QueryNode, continuationKinds: Array<String>, declTypeChildKinds: Array<String>): Bool {
		var exprChildren: Int = 0;
		for (c in node.children) if (!declTypeChildKinds.contains(c.kind)) exprChildren++;
		return exprChildren > 1 || node.span == null || SourceText.isMultiDeclarator(node, continuationKinds);
	}

	/** Whether `rhs` is the null literal — a syntactically definite-null assignment value. */
	private static inline function isNullLitRhs(rhs: Null<QueryNode>, ctx: FlowCtx): Bool {
		return rhs != null && ctx.nullLitKind != null && rhs.kind == ctx.nullLitKind;
	}

	/** Record `name` as `NonNull` in `state`, clearing any `Null` / `MaybeNull` fact (the three sets stay disjoint), deduplicated. */
	private static inline function markNonNull(state: FlowState, name: String): Void {
		if (!state.nonNull.contains(name)) state.nonNull.push(name);
		state.unseen.remove(name);
		state.known.remove(name);
		state.maybe.remove(name);
	}

	/** Record `name` as `Null` in `state`, clearing any `NonNull` / `MaybeNull` fact (the three sets stay disjoint), deduplicated. */
	private static inline function markKnown(state: FlowState, name: String): Void {
		if (!state.known.contains(name)) state.known.push(name);
		dropNonNull(state, name);
		state.maybe.remove(name);
	}

	/**
	 * Record `name` as `MaybeNull` in `state` — a value from a nullable source, pending a narrowing
	 * — clearing any `NonNull` / `Null` fact (the three sets stay disjoint), deduplicated.
	 */
	private static inline function markMaybe(state: FlowState, name: String): Void {
		if (!state.maybe.contains(name)) state.maybe.push(name);
		dropNonNull(state, name);
		state.known.remove(name);
	}

	/** Drop a `NonNull` fact about `name` together with its visibility mark, which never outlives it. */
	private static inline function dropNonNull(state: FlowState, name: String): Void {
		state.nonNull.remove(name);
		state.unseen.remove(name);
	}

	/** Drop every fact about `name` — it becomes `Unknown`. */
	private static inline function clearName(state: FlowState, name: String): Void {
		dropNonNull(state, name);
		state.known.remove(name);
		state.maybe.remove(name);
		killAuxFacts(state, name);
	}

	/** A deep copy of `state` — an isolated branch state the caller can mutate without affecting the original. */
	private static inline function copyState(state: FlowState): FlowState {
		return {
			nonNull: state.nonNull.copy(),
			unseen: state.unseen.copy(),
			known: state.known.copy(),
			maybe: state.maybe.copy(),
			predicates: state.predicates.copy(),
			aliases: state.aliases.copy(),
			present: state.present.copy()
		};
	}

	/** Replace the contents of `state` in place with `next` (the running state is mutated for the caller). */
	private static inline function setState(state: FlowState, next: FlowState): Void {
		refill(state.nonNull, next.nonNull);
		refill(state.unseen, next.unseen);
		refill(state.known, next.known);
		refill(state.maybe, next.maybe);
		refill(state.predicates, next.predicates);
		refill(state.aliases, next.aliases);
		refill(state.present, next.present);
	}

	/** Replace the contents of `into` with `from`'s, keeping `into` the same array. */
	private static inline function refill<T>(into: Array<T>, from: Array<T>): Void {
		into.resize(0);
		for (item in from) into.push(item);
	}

	/**
	 * The verbatim source text of `node`, trimmed — the identity an `ExistsFact` compares
	 * its operands by; `''` for a span-less node, which `existsGuardFact` refuses.
	 */
	private static inline function pathText(node: QueryNode, source: String): String {
		final span: Null<Span> = node.span;
		return span == null ? '' : source.substring(span.from, span.to).trim();
	}

	/** A fresh all-`Unknown` flow state — every fact set empty. */
	private static inline function emptyState(): FlowState {
		return {
			nonNull: [],
			unseen: [],
			known: [],
			maybe: [],
			predicates: [],
			aliases: [],
			present: []
		};
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
		visit: (QueryNode, NullFacts) -> Void, seed: Null<(QueryNode) -> Bool>, declaredNullable: Null<(QueryNode) -> Bool>,
		predicates: Array<NonNullPredicate>, argType: QueryNode -> Null<String>
	): Void {
		final localDeclKinds: Array<String> = shape.localDeclKinds ?? [];
		final nestedFnKinds: Array<String> = MemberKinds.nestedFunctionKinds(shape);
		final ctx: FlowCtx = {
			identKind: identKind,
			assignKind: shape.assignKind,
			eqKind: shape.eqKind,
			notEqKind: shape.notEqKind,
			nullLitKind: shape.nullLiteralKind,
			parenKind: shape.parenKind,
			notKind: shape.notKind,
			writeKinds: shape.writeParentKinds ?? [],
			localDeclKinds: localDeclKinds,
			declTypeChildKinds: shape.declTypeChildKinds ?? [],
			localDeclContinuationKinds: shape.localDeclContinuationKinds ?? [],
			ifKinds: IF_KINDS,
			loopKinds: LOOP_KINDS,
			preTestLoopKinds: PRE_TEST_LOOP_KINDS,
			switchKinds: SWITCH_KINDS,
			tryKinds: TRY_KINDS,
			blockKinds: BLOCK_KINDS,
			controlExitKinds: shape.controlExitKinds ?? [],
			nonNullRhsKinds: NON_NULL_RHS_KINDS,
			opaqueKinds: shape.opaqueKinds ?? [],
			nestedFnKinds: nestedFnKinds,
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
			newExprKind: shape.newExprKind,
			nonNullPredicates: predicates,
			argType: argType,
			fieldAccessKind: shape.fieldAccessKind,
			nullSafeAccessKind: shape.nullSafeAccessKind,
			indexAccessKind: shape.indexAccessKind,
			nullAssertionCalls: shape.nullAssertionCalls ?? [],
			assertTrueCalls: shape.assertTrueCalls ?? [],
			assertFalseCalls: shape.assertFalseCalls ?? [],
			mapExistsMethods: shape.mapExistsMethods ?? [],
			captured: collectCaptured(body, identKind, shape.writeParentKinds ?? [], nestedFnKinds),
			selfScopeDeclKinds: shape.selfScopeDeclKinds,
			binderKinds: BinderScan.binderKinds(shape),
			ownNames: paramNames.concat(collectDeclared(body, localDeclKinds, nestedFnKinds)),
			source: source,
			nullableSourceRhs: seed,
			declaredNullable: declaredNullable,
			visit: visit
		};
		final state: FlowState = emptyState();
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
		final before: Null<Array<String>> = node.children.length == 0 || ownsVisibility(kind, ctx) ? null : visibleIn(state);
		final bound: Array<String> = ctx.selfScopeDeclKinds.contains(kind) ? boundNames(node, ctx) : [];
		final outer: Null<FlowState> = shadow(state, bound);
		transfer(node, state, ctx);
		unshadow(state, node, bound, outer, ctx);
		if (before != null) keepVisible(state, before);
	}

	/** Apply `node`'s flow transfer to `state` — the per-construct dispatch of `walk`. */
	private static function transfer(node: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		final kind: String = node.kind;
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
			killValueFacts(state);
			handleNullAssertionCall(node, state, ctx);
			handleRelationalAssertCall(node, state, ctx);
		} else if (ctx.newExprKind != null && kind == ctx.newExprKind) {
			for (c in node.children) walk(c, state, ctx);
			killValueFacts(state);
		} else if (ctx.blockKinds.contains(kind))
			handleBlock(node, state, ctx);
		else
			for (c in node.children) walk(c, state, ctx);
	}

	/**
	 * Assignment / compound-assignment / increment: narrow the target to `NonNull` for a plain assign
	 * of a non-null value, to `Null` for a plain assign of the null literal, else clear it on both
	 * polarities. A `??=` is routed to its own transfer — its right-hand side runs conditionally.
	 */
	private static function handleWrite(node: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		if (node.kind == ctx.nullCoalAssignKind) {
			handleNullCoalAssign(node, state, ctx);
			return;
		}
		for (c in node.children) walk(c, state, ctx);
		if (node.children.length == 0) return;
		final target: QueryNode = node.children[0];
		final name: Null<String> = target.name;
		final rhs: Null<QueryNode> = node.children.length >= 2 ? node.children[1] : null;
		if (target.kind != ctx.identKind || name == null) {
			// A write through anything but a plain name may land on any map entry; a non-null value
			// assigned to `m[k]` itself is then the one entry known.
			killValueFacts(state);
			final written: Null<ExistsFact> = node.kind == ctx.assignKind && isNonNullRhs(rhs, ctx) ? indexFact(target, ctx) : null;
			if (written != null) state.present.push(written);
			return;
		}
		// A write invalidates every aux fact naming the target — the mark paths never route through clearName.
		killAuxFacts(state, name);
		if (node.kind == ctx.assignKind && isNonNullRhs(rhs, ctx))
			markNonNull(state, name);
		else if (node.kind == ctx.assignKind && isNullLitRhs(rhs, ctx))
			markKnown(state, name);
		else if (node.kind == ctx.assignKind && isNullableSourceRhs(rhs, ctx))
			markMaybe(state, name);
		else
			clearName(state, name);
		if (node.kind == ctx.assignKind) establishAux(state, ctx, name, rhs);
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
		if (target.kind != ctx.identKind || name == null) {
			killValueFacts(state);
			return;
		}
		// A `??=` may reassign the target — every aux fact naming it is stale (the
		// markNonNull path below never routes through clearName's kill).
		killAuxFacts(state, name);
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
		if (ctx.nullAssertionCalls.length == 0) return;
		final dotted: Null<String> = dottedAssertCallee(node, ctx);
		if (dotted == null || !ctx.nullAssertionCalls.contains(dotted)) return;
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
		// A fresh binding shadows any same-named outer aux fact.
		killAuxFacts(state, name);
		if (isMultiBinding(node, ctx.localDeclContinuationKinds, ctx.declTypeChildKinds)) {
			clearName(state, name);
			return;
		}
		final init: Null<QueryNode> = declInit(node, ctx.declTypeChildKinds);
		final nullableInit: Bool = isNullableSourceRhs(init, ctx);
		if (isNonNullRhs(init, ctx))
			markNonNull(state, name);
		else if (isNullLitRhs(init, ctx))
			markKnown(state, name);
		else if (nullableInit && !indexPresentIn(init, state, ctx))
			markMaybe(state, name);
		// The written annotation is asked LAST, and only where the initializer said nothing: a
		// nullable source an `m.exists(k)` guard proves present must stay silent, and its declaration
		// is `Null<V>` all the same.
		else if (!nullableInit && isDeclaredNullable(node, ctx))
			markMaybe(state, name);
		else
			clearName(state, name);
		establishAux(state, ctx, name, init);
	}

	/**
	 * `if` / ternary: narrow each arm by the condition's `!= null` / `== null` guards
	 * (both polarities); analyze each arm in isolation; join the arm-exit states.
	 */
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
		// `== null` proves null — walked to its exit state. The exists-guards (feature 3) ride
		// the same decomposition inside `narrowedCopy`, so BOTH arms get them: the then-arm from
		// a positive `m.exists(k)` conjunct, the else-arm — and hence the fall-through of an
		// early-returning `if (!m.exists(k)) return;` — from a negated disjunct.
		final thenState: FlowState = narrowedCopy(cond, state, ctx, ctx.notEqKind, ctx.eqKind, BOOL_AND_KIND);
		final thenKept: Array<String> = visibleUnwritten(thenState, thenArm, ctx);
		walk(thenArm, thenState, ctx);
		// An unbraced arm declaration (`if (c) var v = null;`) never passes through
		// `handleBlock`'s exit clearing — drop its facts before the join.
		clearDeclaredIn(thenArm, thenState, ctx);
		// Else path: the negated condition (`!(a || b)` = `!a && !b`), so an `== null`
		// disjunct proves non-null and a `!= null` disjunct proves null.
		final elseState: FlowState = narrowedCopy(cond, state, ctx, ctx.eqKind, ctx.notEqKind, BOOL_OR_KIND);
		final elseKept: Array<String> = elseArm == null ? visibleIn(elseState) : visibleUnwritten(elseState, elseArm, ctx);
		if (elseArm != null) {
			walk(elseArm, elseState, ctx);
			clearDeclaredIn(elseArm, elseState, ctx);
		}
		// Join: a fact holds after the `if` only if it holds on every path that falls
		// through to here. An arm that returns / throws contributes no path, so the
		// surviving arm's state passes through unintersected — this gives early-return
		// narrowing (`if (x == null) return;` leaves x non-null after). The compiler joins only
		// two live arms: past a lone survivor it keeps the condition's narrowing and nothing the
		// arm's body proved, so only what was visible on entering that arm stays visible.
		final thenExits: Bool = armExits(thenArm, ctx);
		final elseExits: Bool = elseArm != null && armExits(elseArm, ctx);
		final post: FlowState = if (thenExits && elseExits)
			emptyState();
		else if (thenExits)
			survivor(elseState, elseKept);
		else if (elseExits)
			survivor(thenState, thenKept);
		else
			intersect(thenState, elseState);
		setState(state, post);
	}

	/** Loop: clear every name the loop assigns before walking it (back-edge soundness); the post-state is that cleared state. */
	private static function handleLoop(node: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		killWritten(node, state, ctx);
		// The body is walked once, so a call late in it never reaches the next pass's reads.
		killValueFacts(state);
		final bodyState: FlowState = copyState(state);
		if (!ctx.preTestLoopKinds.contains(node.kind) || node.children.length < 2) {
			for (c in node.children) walk(c, bodyState, ctx);
			return;
		}
		// A pre-test header proves its conjuncts for every iteration, so the body starts from the
		// SAME narrowing an `if` gives its then-arm. `killWritten` above already dropped every name
		// the body assigns, so a re-assignment later in the body cannot ride the header's fact past
		// its own write — `handleWrite` re-decides it at that point.
		final cond: QueryNode = node.children[0];
		walk(cond, bodyState, ctx);
		final narrowed: FlowState = narrowedCopy(cond, bodyState, ctx, ctx.notEqKind, ctx.eqKind, BOOL_AND_KIND);
		for (i in 1...node.children.length) walk(node.children[i], narrowed, ctx);
	}

	/** Fire the consumer callback at `node` with the facts holding in `state`. */
	private static function visitNode(node: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		final facts: NullFacts = {
			nonNull: n -> ctx.ownNames.contains(n) && !ctx.captured.contains(n) && state.nonNull.contains(n),
			nonNullVisible: n ->
				ctx.ownNames.contains(n) && !ctx.captured.contains(n) && state.nonNull.contains(n) && !state.unseen.contains(n),
			isNull: n -> ctx.ownNames.contains(n) && !ctx.captured.contains(n) && state.known.contains(n),
			isMaybeNull: n -> ctx.ownNames.contains(n) && !ctx.captured.contains(n) && state.maybe.contains(n),
			indexPresent: n -> indexPresentIn(n, state, ctx)
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
		var live: Null<QueryNode> = null;
		for (b in branches) {
			final exit: Null<FlowState> = walkBranch(b, state, ctx, subjectName, nullConsumed);
			if (exit != null) {
				exitStates.push(exit);
				live = b;
			}
			if (isNullConsumingCase(b, ctx)) nullConsumed = true;
		}
		// A lone surviving branch is the `if` arm's case: the compiler keeps nothing its body proved.
		if (hasDefault && exitStates.length == 1 && live != null) {
			setState(state, survivor(exitStates[0], visibleUnwritten(state, live, ctx)));
			return;
		}
		var post: Null<FlowState> = hasDefault ? null : copyState(state);
		for (e in exitStates) post = post == null ? e : intersect(post, e);
		setState(state, post ?? emptyState());
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
		final bound: Array<String> = boundNames(b, ctx);
		final outer: Null<FlowState> = shadow(branchState, bound);
		if (nullConsumed && subjectName != null) branchState.maybe.remove(subjectName);
		final guard: Null<QueryNode> = caseGuard(b, ctx);
		if (guard != null) clearMaybeByGuard(guard, branchState, ctx);
		visitNode(b, branchState, ctx);
		for (c in b.children) walk(c, branchState, ctx);
		// Exit clearing: the branch body is not block-wrapped, so a shadow's facts must be
		// dropped here (an inner local declaration or a written pattern capture).
		clearDeclaredIn(b, branchState, ctx);
		unshadow(branchState, b, bound, outer, ctx);
		final last: Null<QueryNode> = b.children.length > 0 ? b.children[b.children.length - 1] : null;
		return last == null || !armExits(last, ctx) ? branchState : null;
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
		// The compiler carries nothing a `try` or its catches prove past the construct — only what
		// was visible on entering it and is written nowhere inside.
		final kept: Array<String> = visibleUnwritten(state, node, ctx);
		final tryState: FlowState = copyState(state);
		walk(body, tryState, ctx);
		final catchEntry: FlowState = copyState(state);
		killWritten(body, catchEntry, ctx);
		final exitStates: Array<FlowState> = [];
		if (!armExits(body, ctx)) exitStates.push(tryState);
		for (i in 1...node.children.length) {
			final clause: QueryNode = node.children[i];
			final clauseState: FlowState = copyState(catchEntry);
			final bound: Array<String> = ctx.selfScopeDeclKinds.contains(clause.kind) ? boundNames(clause, ctx) : [];
			final outer: Null<FlowState> = shadow(clauseState, bound);
			visitNode(clause, clauseState, ctx);
			for (c in clause.children) walk(c, clauseState, ctx);
			// Exit clearing: a bare-body shadow declaration must not leak out under the outer binding's name.
			clearDeclaredIn(clause, clauseState, ctx);
			unshadow(clauseState, clause, bound, outer, ctx);
			final last: Null<QueryNode> = clause.children.length > 0 ? clause.children[clause.children.length - 1] : null;
			if (last == null || !armExits(last, ctx)) exitStates.push(clauseState);
		}
		var post: Null<FlowState> = null;
		for (e in exitStates) post = post == null ? e : intersect(post, e);
		setState(state, survivor(post ?? emptyState(), kept));
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
		collectNarrow(guard, names, ctx, ctx.notEqKind, BOOL_AND_KIND, true);
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
		for (c in b.children)
			if (ctx.plainCasePatternKind != null && c.kind == ctx.plainCasePatternKind)
				for (p in c.children)
					if (p.kind == nl) return true;
		return false;
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
		for (n in collectDeclared(scope, ctx.localDeclKinds, ctx.nestedFnKinds)) clearName(state, n);
	}

	/**
	 * Statement-list block: children share one running state; block-local
	 * declarations are cleared on exit so their facts do not leak out.
	 */
	private static function handleBlock(node: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		for (c in node.children) walk(c, state, ctx);
		for (n in collectDeclared(node, ctx.localDeclKinds, ctx.nestedFnKinds)) clearName(state, n);
	}

	/** Whether `rhs` is a syntactically non-null expression (a constructor or a non-null literal). */
	private static function isNonNullRhs(rhs: Null<QueryNode>, ctx: FlowCtx): Bool {
		return rhs != null && ctx.nonNullRhsKinds.contains(rhs.kind);
	}

	/**
	 * Whether `rhs` is a nullable source per the consumer's seed predicate (mechanism A) —
	 * always false when no seed was supplied, so the flow checks never see a `MaybeNull` fact.
	 */
	private static function isNullableSourceRhs(rhs: Null<QueryNode>, ctx: FlowCtx): Bool {
		final seed: Null<(QueryNode) -> Bool> = ctx.nullableSourceRhs;
		return rhs != null && seed != null && seed(rhs);
	}

	/** Whether `decl`, a local `var` / `final` declaration, carries an explicitly nullable written annotation. */
	private static function isDeclaredNullable(decl: QueryNode, ctx: FlowCtx): Bool {
		final declared: Null<(QueryNode) -> Bool> = ctx.declaredNullable;
		return declared != null && declared(decl);
	}

	/**
	 * Clear every name written anywhere in `node`'s subtree (any write-kind
	 * whose first child is a plain identifier) on both polarities.
	 */
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
		final viaSafeNav: Array<String> = [];
		collectNarrow(cond, nonNull, ctx, cmpNonNull, combineKind, true, viaSafeNav);
		// What the compiler narrows too: the direct comparisons alone, before the three kinds of
		// proof it cannot follow — safe navigation, a laundered Bool, an alias — join them.
		final visible: Array<String> = nonNull.copy();
		for (n in viaSafeNav) nonNull.push(n);
		final known: Array<String> = [];
		collectNarrow(cond, known, ctx, cmpKnown, combineKind, false);
		// Feature 1: a bare Bool conjunct/disjunct carrying a laundered-guard fact narrows its target.
		addLaunderedNarrowing(cond, base, ctx, combineKind, nonNull, known);
		// Feature 2: a narrowed name narrows every local aliased to it, same polarity.
		expandAliases(base, nonNull);
		expandAliases(base, known);
		// Feature 3: an `m.exists(k)` test of the polarity this branch holds marks the pair
		// present, so a map read under the guard is neither seeded `MaybeNull` nor reported
		// point-wise. `wantNegated` mirrors the null-comparison duality this call already
		// carries: the then-arm / `&&` right side (`combineKind == 'And'`) consumes a POSITIVE
		// test, the else-arm / `||` right side the negation of one.
		final present: Array<ExistsFact> = [];
		collectExists(cond, present, ctx, combineKind, combineKind == BOOL_OR_KIND);
		for (e in present) if (!e.names.exists(n -> written.contains(n))) out.present.push(e);
		for (n in nonNull) if (!written.contains(n)) {
			final seen: Bool = visible.contains(n) || out.nonNull.contains(n) && !out.unseen.contains(n);
			markNonNull(out, n);
			if (!seen && !out.unseen.contains(n)) out.unseen.push(n);
		}
		for (n in known) if (!written.contains(n)) markKnown(out, n);
		return out;
	}

	/** The names mutated inside any nested function value within `body` — excluded from narrowing for the whole function. */
	private static function collectCaptured(
		body: QueryNode, identKind: String, writeKinds: Array<String>, nestedFnKinds: Array<String>
	): Array<String> {
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
			if (nestedFnKinds.contains(n.kind))
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
		cond: QueryNode, out: Array<String>, ctx: FlowCtx, cmpKind: Null<String>, combineKind: String, provesNonNull: Bool,
		?viaSafeNav: Array<String>
	): Void {
		final kind: String = cond.kind;
		if (cmpKind != null && kind == cmpKind) {
			// A SAFE-NAVIGATION operand only ever proves the NON-NULL side, and `provesNonNull` — not
			// `cmpKind` — is what says which side this call is filling: the operator alone cannot,
			// since the else-arm collects non-null names through `== null` by duality. `x?.a` null
			// leaves `x` itself entirely unconstrained, so the known-null slot must never take one.
			final direct: Null<QueryNode> = nullComparisonOperand(cond, ctx.identKind, ctx.nullLitKind);
			final operand: Null<QueryNode> = direct ?? (provesNonNull ? safeNavChainRoot(cond, ctx) : null);
			final nm: Null<String> = operand?.name;
			// A caller that tracks compiler visibility takes the safe-navigation names apart: the
			// compiler narrows `x` on `x != null`, never on `x?.f != null`.
			if (nm != null) (direct == null ? viaSafeNav ?? out : out).push(nm);
		} else if (kind == combineKind) {
			for (c in cond.children) collectNarrow(c, out, ctx, cmpKind, combineKind, provesNonNull, viaSafeNav);
		} else if (ctx.parenKind != null && kind == ctx.parenKind && cond.children.length == 1) {
			collectNarrow(cond.children[0], out, ctx, cmpKind, combineKind, provesNonNull, viaSafeNav);
		} else if (ctx.notKind != null && kind == ctx.notKind && cond.children.length == 1) {
			// Feature 3: `!(…)` flips the comparison polarity AND the combine operator (De Morgan) — a
			// negand proving x null then proves x non-null, and its `&&`/`||` swap; nested `!` unwinds
			// by recursion (double-not restores the original polarity).
			final flipCmp: Null<String> = if (cmpKind == ctx.notEqKind)
				ctx.eqKind
			else if (cmpKind == ctx.eqKind)
				ctx.notEqKind
			else
				cmpKind;
			final flipCombine: String = combineKind == BOOL_AND_KIND ? BOOL_OR_KIND : BOOL_AND_KIND;
			collectNarrow(cond.children[0], out, ctx, flipCmp, flipCombine, provesNonNull, viaSafeNav);
		} else if (provesNonNull && cmpKind != null && cmpKind == ctx.notEqKind && kind == ctx.callKind) {
			// A true NON-NULL PREDICATE call proves its argument the way `x != null` does — in the
			// polarity a `!= null` holds here. The compiler's own narrowing is not claimed for it.
			for (n in predicateArgs(cond, ctx)) (viaSafeNav ?? out).push(n);
		}
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
		return ctx.controlExitKinds.contains(arm.kind) || isLoopJump(arm, ctx) || arm.kind == ctx.exprStmtKind && arm.children.length == 1
			&& isLoopJump(arm.children[0], ctx) || ctx.blockKinds.contains(arm.kind) && arm.children.length > 0
			&& armExits(arm.children[arm.children.length - 1], ctx);
	}

	/** Whether `node` is a bare loop-jump identifier (`break` / `continue` — `RefShape.loopJumpNames`). */
	private static function isLoopJump(node: QueryNode, ctx: FlowCtx): Bool {
		final name: Null<String> = node.name;
		return node.kind == ctx.identKind && name != null && ctx.loopJumpNames.contains(name);
	}

	/** The facts holding on both `a` and `b` — a name keeps a polarity after a join only if it held it on both arms. */
	private static function intersect(a: FlowState, b: FlowState): FlowState {
		final nonNull: Array<String> = [for (n in a.nonNull) if (b.nonNull.contains(n)) n];
		return {
			nonNull: nonNull,
			unseen: unseenAfterJoin(nonNull, a, b),
			known: [for (n in a.known) if (b.known.contains(n)) n],
			maybe: [for (n in a.maybe) if (b.maybe.contains(n)) n],
			predicates: [
				for (p in a.predicates) if (b.predicates.exists(q ->
					q.bool == p.bool && q.target == p.target && q.notEq == p.notEq && q.compound == p.compound
				))
					p
			],
			aliases: [
				for (x in a.aliases) if (b.aliases.exists(q -> (q.a == x.a && q.b == x.b) || (q.a == x.b && q.b == x.a))) x
			],
			present: [
				for (e in a.present) if (b.present.exists(q -> q.map == e.map && q.key == e.key && q.value == e.value)) e
			]
		};
	}

	/**
	 * The names `node` binds for its own subtree, read off the grammar's binder vocabulary
	 * (`BinderScan.binderKinds`) so a new binder spelling is covered the day it is declared: a
	 * `selfScopeDeclKinds` construct's own name (`for (x in …)`, `catch (x)`) and every binder child
	 * it carries (`k => x`), and every name a `case` branch's patterns bind (`BinderScan.casePatternNames`
	 * over the first pattern and each comma alternative — `case x:`, `case var x:`, `case Some(var x):`).
	 * Lambda and local-function parameters bind in a unit of their own (`forEachFunctionUnit`), and a
	 * block's `var` is position-scoped (`handleBlock` clears it on exit), so neither is answered here.
	 */
	private static function boundNames(node: QueryNode, ctx: FlowCtx): Array<String> {
		final out: Array<String> = [];
		function add(name: Null<String>): Void {
			if (name != null && !out.contains(name)) out.push(name);
		}
		if (ctx.selfScopeDeclKinds.contains(node.kind)) {
			add(node.name);
			for (c in node.children) if (ctx.binderKinds.contains(c.kind)) add(c.name);
		}
		if (node.kind == ctx.caseBranchKind && node.children.length > 0) for (i in 0...node.children.length) {
			final c: QueryNode = node.children[i];
			if (i == 0 || c.kind == ctx.plainCasePatternKind)
				for (n in BinderScan.casePatternNames(c, ctx.plainCasePatternKind, ctx.binderKinds)) add(n);
		}
		return out;
	}

	/**
	 * Enter the scope of `bound`: every fact about those names is dropped, since inside it they
	 * denote fresh bindings. Returns the state as it was, for `unshadow` — null when nothing is bound.
	 */
	private static function shadow(state: FlowState, bound: Array<String>): Null<FlowState> {
		if (bound.length == 0) return null;
		final outer: FlowState = copyState(state);
		for (n in bound) clearName(state, n);
		return outer;
	}

	/**
	 * Leave the scope of `bound` opened on `node`: the inner bindings' facts are dropped, and each
	 * outer name `node` writes nowhere gets back the `NonNull` / `Null` / `MaybeNull` fact `outer`
	 * held for it — the compiler keeps an outer local's narrowing across a scope that shadowed it.
	 * A name written inside stays `Unknown`: the write may be the outer one's.
	 */
	private static function unshadow(state: FlowState, node: QueryNode, bound: Array<String>, outer: Null<FlowState>, ctx: FlowCtx): Void {
		if (outer == null) return;
		final written: Array<String> = [];
		collectWrites(node, written, ctx);
		for (n in bound) {
			clearName(state, n);
			if (written.contains(n)) continue;
			if (outer.nonNull.contains(n)) {
				markNonNull(state, n);
				if (outer.unseen.contains(n)) state.unseen.push(n);
			} else if (outer.known.contains(n))
				markKnown(state, n);
			else if (outer.maybe.contains(n))
				markMaybe(state, n);
		}
	}

	/**
	 * Whether `kind` states its own visibility rule, so `walk` leaves its post-state alone: the constructs the compiler is
	 * probed to follow in order (a block, a statement, a write, a declaration, a call, a parenthesis, an array literal) and
	 * the constructs whose handlers apply the rule themselves (`if`, `switch`, `try`). Every other kind keeps visible only
	 * what was visible before it.
	 */
	private static function ownsVisibility(kind: String, ctx: FlowCtx): Bool {
		return ctx.blockKinds.contains(kind) || kind == ctx.exprStmtKind || ctx.writeKinds.contains(kind)
			|| ctx.localDeclKinds.contains(kind) || kind == ctx.callKind || kind == ctx.parenKind || kind == ARRAY_KIND
			|| ctx.ifKinds.contains(kind) || ctx.switchKinds.contains(kind) || ctx.tryKinds.contains(kind);
	}

	/** The `nonNull` names `state` proves visibly. */
	private static function visibleIn(state: FlowState): Array<String> {
		return [for (n in state.nonNull) if (!state.unseen.contains(n)) n];
	}

	/** The names visible in `state` that `node` writes nowhere — what survives a construct the compiler does not follow into. */
	private static function visibleUnwritten(state: FlowState, node: QueryNode, ctx: FlowCtx): Array<String> {
		final written: Array<String> = [];
		collectWrites(node, written, ctx);
		return [for (n in visibleIn(state)) if (!written.contains(n)) n];
	}

	/** Mark unseen every `nonNull` name of `state` outside `kept`: a construct keeps a name visible only when its rule names it. */
	private static function keepVisible(state: FlowState, kept: Array<String>): Void {
		for (n in state.nonNull) if (!kept.contains(n) && !state.unseen.contains(n)) state.unseen.push(n);
	}

	/** `state` with `keepVisible(state, kept)` applied — the post-state of a lone surviving path. */
	private static function survivor(state: FlowState, kept: Array<String>): FlowState {
		keepVisible(state, kept);
		return state;
	}

	/** The joined `nonNull` names either arm proved only invisibly — a join is visible only where both arms were. */
	private static function unseenAfterJoin(nonNull: Array<String>, a: FlowState, b: FlowState): Array<String> {
		return [for (n in nonNull) if (a.unseen.contains(n) || b.unseen.contains(n)) n];
	}

	/**
	 * Invalidate every auxiliary fact (laundered predicate, alias, exists-guard) naming
	 * `name` on either side — its value just changed or its binding left scope, so a fact
	 * captured against the old value must not survive. Called on every write and every
	 * scope exit (via `clearName`); narrowing (`markNonNull` / `markKnown`) deliberately
	 * does NOT invalidate — a guard preserves aliases and predicates.
	 */
	private static function killAuxFacts(state: FlowState, name: String): Void {
		if (state.predicates.length > 0) state.predicates = [for (p in state.predicates) if (p.bool != name && p.target != name) p];
		if (state.aliases.length > 0) state.aliases = [for (a in state.aliases) if (a.a != name && a.b != name) a];
		if (state.present.length > 0) state.present = [for (e in state.present) if (!e.names.contains(name)) e];
	}

	/**
	 * Establish an auxiliary fact from a plain assignment / declaration `name = rhs`. A
	 * right-hand side that is EXACTLY a null-comparison of a plain own-name ident records a
	 * laundered-guard predicate (`name ⇒ target !=/== null`); a right-hand side that is a
	 * plain own-name ident copy records a bidirectional alias. Anything else (a field, a
	 * call, a composite expression) establishes nothing — refused. Both members must be own
	 * names (locals/params, never call-mutable fields) and neither may be closure-captured.
	 */
	private static function establishAux(state: FlowState, ctx: FlowCtx, name: String, rhs: Null<QueryNode>): Void {
		if (rhs == null || !ctx.ownNames.contains(name) || ctx.captured.contains(name)) return;
		final r: QueryNode = BoolExprShape.unwrapParens(rhs, ctx.parenKind);
		final rk: String = r.kind;
		if (rk == ctx.notEqKind || rk == ctx.eqKind) {
			final operand: Null<QueryNode> = nullComparisonOperand(r, ctx.identKind, ctx.nullLitKind);
			final t: Null<String> = operand?.name;
			if (t != null && t != name && ctx.ownNames.contains(t) && !ctx.captured.contains(t)) {
				final target: String = t;
				state.predicates.push({
					bool: name,
					target: target,
					notEq: rk == ctx.notEqKind,
					compound: false
				});
			}
			return;
		}
		if (rk == BOOL_AND_KIND) {
			establishCompoundPredicates(state, ctx, name, r);
			return;
		}
		if (rk != ctx.identKind) return;
		final other: Null<String> = r.name;
		if (other == null || other == name || !ctx.ownNames.contains(other) || ctx.captured.contains(other)) return;
		final copy: String = other;
		state.aliases.push({ a: name, b: copy });
	}

	/**
	 * Collect into `out` the plain idents appearing as bare conjuncts / disjuncts of
	 * `cond` (descending the `combineKind` operator and parentheses) — each a candidate
	 * laundered-guard Bool. Mirrors `collectNarrow`, but gathers bare identifiers rather
	 * than null-comparison operands; a comparison subtree is NOT descended, so its operand
	 * is never mistaken for a laundered Bool.
	 */
	private static function collectPredicateIdents(cond: QueryNode, out: Array<String>, ctx: FlowCtx, combineKind: String): Void {
		final kind: String = cond.kind;
		if (kind == ctx.identKind) {
			final nm: Null<String> = cond.name;
			if (nm != null && !out.contains(nm)) out.push(nm);
		} else if (kind == combineKind) {
			for (c in cond.children) collectPredicateIdents(c, out, ctx, combineKind);
		} else if (ctx.parenKind != null && kind == ctx.parenKind && cond.children.length == 1) {
			collectPredicateIdents(cond.children[0], out, ctx, combineKind);
		}
	}

	/**
	 * Feature 1: for each bare Bool conjunct/disjunct of `cond` carrying a laundered-guard
	 * predicate in `base`, add its target to the `nonNull` or `known` list. `combineKind ==
	 * 'And'` marks the then-arm (the Bool is true — its fact applies directly), otherwise
	 * the else-arm (the Bool is false — the De Morgan mirror applies).
	 */
	private static function addLaunderedNarrowing(
		cond: QueryNode, base: FlowState, ctx: FlowCtx, combineKind: String, nonNull: Array<String>, known: Array<String>
	): Void {
		final idents: Array<String> = [];
		collectPredicateIdents(cond, idents, ctx, combineKind);
		// Feature 1: a Bool aliased to a laundered guard (`var ok2 = ok`) inherits its predicate —
		// grow the ident set by transitive alias closure before the predicate lookup.
		expandAliases(base, idents);
		final thenArm: Bool = combineKind == BOOL_AND_KIND;
		for (id in idents) for (fact in base.predicates) if (fact.bool == id) {
			// Feature 2: a compound predicate (`ok = a != null && b`) is one-way — its truth implies
			// each conjunct, but its falsity (the else-arm) implies nothing, so the De Morgan mirror
			// is unsound and skipped.
			if (!thenArm && fact.compound) continue;
			if (thenArm == fact.notEq)
				nonNull.push(fact.target);
			else
				known.push(fact.target);
		}
	}

	/**
	 * Feature 2: grow `names` with every local transitively aliased to one already in it
	 * (a direct `v = u` copy makes the two share a reference, so they share a null
	 * polarity). A write to any member of a pair severs it (`killAuxFacts`), so the
	 * transitive walk stays sound.
	 */
	private static function expandAliases(base: FlowState, names: Array<String>): Void {
		var i: Int = 0;
		while (i < names.length) {
			final n: String = names[i];
			for (al in base.aliases) {
				final other: Null<String> = if (al.a == n)
					al.b
				else if (al.b == n)
					al.a
				else
					null;
				if (other != null && !names.contains(other)) names.push(other);
			}
			i++;
		}
	}

	/**
	 * Feature 3: the `m.exists(k)` membership test `cond` states, as an `ExistsFact`, else null.
	 * Both operands may be any PURE REF PATH — `m`, `this.m`, `a.b.model.subactions`,
	 * `outer[i]` — and are identified by their verbatim source text; the key may also be a
	 * literal. No identifier either operand mentions may be closure-captured. The fact marks
	 * the pair present on the guarded branch, so a `var u = m[k]` there is not seeded
	 * `MaybeNull` and a `m[k].f` there is not reported point-wise.
	 */
	private static function existsGuardFact(rawCond: QueryNode, ctx: FlowCtx): Null<ExistsFact> {
		if (ctx.callKind == null || ctx.fieldAccessKind == null || ctx.mapExistsMethods.length == 0) return null;
		final cond: QueryNode = BoolExprShape.unwrapParens(rawCond, ctx.parenKind);
		if (cond.kind != ctx.callKind || cond.children.length != 2) return null;
		final callee: QueryNode = cond.children[0];
		final method: Null<String> = callee.name;
		if (callee.kind != ctx.fieldAccessKind || method == null || !ctx.mapExistsMethods.contains(method) || callee.children.length != 1)
			return null;
		return pairFact(callee.children[0], cond.children[1], ctx, false);
	}

	/**
	 * The fact that the pair (`recv`, `key`) is present — a VALUE fact when `value`, proven by the
	 * entry itself rather than by `exists` — or null when either operand is not a PURE REF PATH, has no
	 * source text, or mentions a closure-captured name.
	 */
	private static function pairFact(recv: QueryNode, key: QueryNode, ctx: FlowCtx, value: Bool): Null<ExistsFact> {
		if (!pureRefPath(recv, ctx) || !pureRefPath(key, ctx)) return null;
		final mapText: String = pathText(recv, ctx.source);
		final keyText: String = pathText(key, ctx.source);
		if (mapText == '' || keyText == '') return null;
		final names: Array<String> = [];
		collectPathNames(recv, names, ctx);
		collectPathNames(key, names, ctx);
		for (n in names) if (ctx.captured.contains(n)) return null;
		return {
			map: mapText,
			key: keyText,
			names: names,
			value: value
		};
	}

	/** The value fact of an index read `rawNode` (`m[k]`, parentheses unwrapped), else null. */
	private static function indexFact(rawNode: QueryNode, ctx: FlowCtx): Null<ExistsFact> {
		final node: QueryNode = BoolExprShape.unwrapParens(rawNode, ctx.parenKind);
		return ctx.indexAccessKind != null && node.kind == ctx.indexAccessKind && node.children.length == 2
			? pairFact(node.children[0], node.children[1], ctx, true)
			: null;
	}

	/**
	 * The value fact `rawCond` states when it compares an index read against `null` with `cmpKind`
	 * (`m[k] != null`, `null != m[k]`, parentheses unwrapped), else null. `collectExists` passes the
	 * operator whose truth on this branch means the entry is not null.
	 */
	private static function nullCompareFact(rawCond: QueryNode, ctx: FlowCtx, cmpKind: Null<String>): Null<ExistsFact> {
		final cond: QueryNode = BoolExprShape.unwrapParens(rawCond, ctx.parenKind);
		final nullLit: Null<String> = ctx.nullLitKind;
		if (cmpKind == null || nullLit == null || cond.kind != cmpKind || cond.children.length != 2) return null;
		final left: QueryNode = cond.children[0];
		final right: QueryNode = cond.children[1];
		return if (right.kind == nullLit)
			indexFact(left, ctx)
		else if (left.kind == nullLit)
			indexFact(right, ctx)
		else
			null;
	}

	/**
	 * Drop every VALUE fact: a call, a `new`, or a write through anything but a plain name may have
	 * changed a map entry without writing either operand's name, which is all the name-keyed kill sees.
	 */
	private static function killValueFacts(state: FlowState): Void {
		if (state.present.exists(e -> e.value)) state.present = state.present.filter(e -> !e.value);
	}

	/**
	 * Whether `node` is a PURE REF PATH — a constant, an identifier, a field access, an index
	 * access, or a parenthesized one of those. Everything else — a call above all — is refused,
	 * because an `ExistsFact` identifies its operands by SOURCE TEXT, and two evaluations of
	 * `f().m` may answer two different maps while spelling the same.
	 *
	 * The two accepted classes are what an exists-guard's operands are ever made of: the map is
	 * a path (`m`, `this.m`, `a.b.model.subactions`, `outer[i]`), the key a path or a constant
	 * (`m.exists('fix')` guarding `m['fix']` is the commonest form in real code). Nothing else
	 * is admitted, so a shape nobody has thought of fails closed rather than leaking in.
	 */
	private static function pureRefPath(node: QueryNode, ctx: FlowCtx): Bool {
		if (constantExpr(node, ctx)) return true;
		final kind: String = node.kind;
		final structural: Bool = kind == ctx.identKind || kind == ctx.fieldAccessKind || kind == ctx.indexAccessKind
			|| (ctx.parenKind != null && kind == ctx.parenKind);
		return structural && node.children.foreach(c -> pureRefPath(c, ctx));
	}

	/**
	 * Whether `node`'s whole subtree reads no name and calls nothing — its source text IS its
	 * value. That is the grammar-agnostic spelling of "a literal", which matters because a
	 * literal is not always a leaf: Haxe projects the key `'fix'` as
	 * `SingleStringExpr(Literal fix)`, and a leaf-only test refused every
	 * `if (m.exists('fix')) m['fix'].f` in the corpus. An interpolated string or a
	 * `new` expression mentions an identifier and is refused — a safe miss.
	 */
	private static function constantExpr(node: QueryNode, ctx: FlowCtx): Bool {
		return node.kind != ctx.identKind && node.kind != ctx.callKind && node.children.foreach(c -> constantExpr(c, ctx));
	}

	/** Collect into `out` every identifier name `node`'s subtree mentions — the kill set of an `ExistsFact` built from it. */
	private static function collectPathNames(node: QueryNode, out: Array<String>, ctx: FlowCtx): Void {
		final name: Null<String> = node.name;
		if (node.kind == ctx.identKind && name != null && !out.contains(name)) out.push(name);
		for (c in node.children) collectPathNames(c, out, ctx);
	}

	/**
	 * Collect into `out` every `m.exists(k)` test a condition proves TRUE for one branch,
	 * decomposed exactly as `collectNarrow` decomposes null comparisons: the then-arm via
	 * `('And', wantNegated = false)` — each positive conjunct — and the else-arm via
	 * `('Or', wantNegated = true)`, where the branch holds the condition's negation and so a
	 * NEGATED disjunct (`if (!m.exists(k)) return;`) is what proves presence. A `!` flips both
	 * the wanted polarity and the combining operator (De Morgan), a parenthesized wrapper is
	 * descended, and any other shape proves nothing.
	 */
	private static function collectExists(
		cond: QueryNode, out: Array<ExistsFact>, ctx: FlowCtx, combineKind: String, wantNegated: Bool
	): Void {
		final kind: String = cond.kind;
		if (kind == combineKind) {
			for (c in cond.children) collectExists(c, out, ctx, combineKind, wantNegated);
		} else if (ctx.parenKind != null && kind == ctx.parenKind && cond.children.length == 1) {
			collectExists(cond.children[0], out, ctx, combineKind, wantNegated);
		} else if (ctx.notKind != null && kind == ctx.notKind && cond.children.length == 1) {
			collectExists(cond.children[0], out, ctx, combineKind == BOOL_AND_KIND ? BOOL_OR_KIND : BOOL_AND_KIND, !wantNegated);
		} else {
			final fact: Null<ExistsFact> = wantNegated
				? nullCompareFact(cond, ctx, ctx.eqKind)
				: existsGuardFact(cond, ctx) ?? nullCompareFact(cond, ctx, ctx.notEqKind);
			if (fact != null) out.push(fact);
		}
	}

	/**
	 * Feature 3: whether `node` is a map read `m[k]` whose (map, key) pair a dominating
	 * exists-guard in `state` proves present. The ONE presence predicate: the `MaybeNull`
	 * seed asks it about a declaration's right-hand side, and `NullFacts.indexPresent`
	 * hands the same answer to the point-wise `possible-null-dereference`.
	 *
	 * Residual, shared with every other consumer of these facts and inherited from the
	 * name-keyed lattice: a mutation that removes the key without writing either operand's
	 * NAME — `m.remove(k)`, a call that clears the map — leaves the fact standing. Widening
	 * the kill to any call on the map would trade that for silence on the guard's own test.
	 */
	private static function indexPresentIn(rawNode: Null<QueryNode>, state: FlowState, ctx: FlowCtx): Bool {
		if (rawNode == null || ctx.indexAccessKind == null || state.present.length == 0) return false;
		final node: QueryNode = BoolExprShape.unwrapParens(rawNode, ctx.parenKind);
		if (node.kind != ctx.indexAccessKind || node.children.length < 2) return false;
		final recv: QueryNode = node.children[0];
		final key: QueryNode = node.children[1];
		if (!pureRefPath(recv, ctx) || !pureRefPath(key, ctx)) return false;
		final mapText: String = pathText(recv, ctx.source);
		final keyText: String = pathText(key, ctx.source);
		return mapText != '' && keyText != '' && state.present.exists(e -> e.map == mapText && e.key == keyText);
	}

	/**
	 * Feature 2: seed one-way (`compound`) predicates from a conjunctive Bool RHS
	 * (`ok = a != null && b == null && …`). Refused outright if ANY `||` appears anywhere
	 * in the RHS — its truth would then no longer imply each null-comparison conjunct. Each
	 * `!= null` conjunct of a plain own-name ident yields `ok ⇒ target != null`, each `==
	 * null` conjunct `ok ⇒ target == null`; only the then-arm (ok true) consumes these — the
	 * else-arm (ok false) implies nothing, so `addLaunderedNarrowing` suppresses its mirror.
	 */
	private static function establishCompoundPredicates(state: FlowState, ctx: FlowCtx, name: String, andRhs: QueryNode): Void {
		if (containsOr(andRhs)) return;
		// A conjunct target that is ALSO written elsewhere in the RHS (`u != null && (u = mk()) ==
		// null`) cannot be trusted — `ok` reflects the pre-write value, so exclude it, mirroring
		// narrowedCopy's cond-self-write guard.
		final written: Array<String> = [];
		collectWrites(andRhs, written, ctx);
		final nn: Array<String> = [];
		collectNarrow(andRhs, nn, ctx, ctx.notEqKind, BOOL_AND_KIND, true);
		final kn: Array<String> = [];
		collectNarrow(andRhs, kn, ctx, ctx.eqKind, BOOL_AND_KIND, false);
		for (t in nn) if (
			t != name && !written.contains(t) && ctx.ownNames.contains(t) && !ctx.captured.contains(t)
		) state.predicates.push({
			bool: name,
			target: t,
			notEq: true,
			compound: true
		});
		for (t in kn) if (
			t != name && !written.contains(t) && ctx.ownNames.contains(t) && !ctx.captured.contains(t)
		) state.predicates.push({
			bool: name,
			target: t,
			notEq: false,
			compound: true
		});
	}

	/** Whether `node`'s subtree contains any logical-`||` operator — the compound-predicate refusal trigger. */
	private static function containsOr(node: QueryNode): Bool {
		return node.kind == BOOL_OR_KIND || node.children.exists(c -> containsOr(c));
	}

	/**
	 * A relational assertion call (`Assert.isTrue(u != null)` / `Assert.isFalse(u == null)`):
	 * its boolean-expression first argument is asserted TRUE (`assertTrueCalls`) or FALSE
	 * (`assertFalseCalls`), so every plain own-name ident that argument narrows non-null on
	 * that outcome is cleared from `state.maybe` after the call. Reuses `collectNarrow` — the
	 * then-arm polarity (`!= null`, `&&`) for a truth assert, the else-arm polarity (`== null`,
	 * `||`, De-Morgan `!`) for a falsity one — so a conjunction narrows each provable conjunct
	 * while a non-narrowable one is silently skipped, and an `||` in a truth assert (or `&&` in
	 * a falsity one) proves no single operand and narrows nothing. `maybe`-only, exactly like
	 * `handleNullAssertionCall`: it adds NO `NonNull` fact, so the six base flow checks stay
	 * byte-identical AND no guard-deleting autofix can ever fire off it — the worst it can do is
	 * suppress a MaybeNull deref finding, never introduce one. Sound even though utest asserts
	 * record-and-continue rather than throw: the assert documents the programmer's non-null
	 * intent, so quieting a following deref is a false-positive suppression (see the class note).
	 */
	private static function handleRelationalAssertCall(node: QueryNode, state: FlowState, ctx: FlowCtx): Void {
		if (ctx.assertTrueCalls.length == 0 && ctx.assertFalseCalls.length == 0) return;
		final dotted: Null<String> = dottedAssertCallee(node, ctx);
		if (dotted == null) return;
		final asTrue: Bool = ctx.assertTrueCalls.contains(dotted);
		final asFalse: Bool = ctx.assertFalseCalls.contains(dotted);
		// In neither list, or (a misconfiguration) in both — narrow nothing.
		if (asTrue == asFalse) return;
		final arg: QueryNode = node.children[1];
		final names: Array<String> = [];
		if (asTrue)
			collectNarrow(arg, names, ctx, ctx.notEqKind, BOOL_AND_KIND, true);
		else
			collectNarrow(arg, names, ctx, ctx.eqKind, BOOL_OR_KIND, true);
		for (n in names) state.maybe.remove(n);
	}

	/**
	 * For a `Recv.method(arg, …)` call whose receiver is a plain identifier and which carries at
	 * least one argument, the dotted `Recv.method` string; null otherwise. The shared callee
	 * recogniser of the two assertion-call handlers (`handleNullAssertionCall` /
	 * `handleRelationalAssertCall`).
	 */
	private static function dottedAssertCallee(node: QueryNode, ctx: FlowCtx): Null<String> {
		if (node.children.length < 2) return null;
		final call: Null<MethodCall> = NodeShape.methodCall(node, ctx.fieldAccessKind);
		if (call == null) return null;
		final recvName: Null<String> = call.receiver.name;
		return call.receiver.kind != ctx.identKind || recvName == null ? null : '${recvName}.${call.method}';
	}

	/**
	 * The plain identifier a null-comparison's SAFE-NAVIGATION operand is rooted at, when the step
	 * directly off that root is the safe access itself — `account?.UserInfo != null` answers
	 * `account`, and so does `account?.UserInfo.email != null` / `account?.load() != null`, because
	 * `?.` short-circuits the WHOLE remaining chain to null. Null for every other shape.
	 *
	 * Only the NON-NULL direction may use it, and `collectNarrow` is what enforces that: `x?.a !=
	 * null` proves `x != null`, but `x?.a == null` proves nothing about `x` — the member may simply
	 * be null on a perfectly non-null receiver.
	 *
	 * The step directly off the root must be the safe one. `x.a?.b != null` is refused: with a null
	 * `x` that condition THROWS rather than evaluating to null, so reading the false branch as
	 * evidence would be the "it did not crash, therefore it was non-null" argument — which is
	 * exactly the crash this family exists to report.
	 *
	 * Deliberately NOT folded into the public `nullComparisonOperand`: four other checks read that
	 * predicate (`always-null-comparison`, `dead-null-guard`, `optional-param-shorthand`,
	 * `nullable-switch-missing-null`) and each treats its answer as "this comparison is ABOUT that
	 * name" — which `x?.a != null` is not, since the comparison also tests `a`.
	 */
	private static function safeNavChainRoot(cond: QueryNode, ctx: FlowCtx): Null<QueryNode> {
		final safeKind: Null<String> = ctx.nullSafeAccessKind;
		final nullLit: Null<String> = ctx.nullLitKind;
		if (safeKind == null || nullLit == null || cond.children.length != 2) return null;
		final left: QueryNode = cond.children[0];
		final right: QueryNode = cond.children[1];
		final leftIsNull: Bool = left.kind == nullLit;
		if (leftIsNull == (right.kind == nullLit)) return null;
		final chainKinds: Array<String> = [
			for (k in [safeKind, ctx.fieldAccessKind, ctx.callKind, ctx.indexAccessKind]) if (k != null) k
		];
		var cur: QueryNode = leftIsNull ? right : left;
		while (cur.children.length >= 1 && chainKinds.contains(cur.kind)) {
			final receiver: QueryNode = cur.children[0];
			if (receiver.kind == ctx.identKind) return cur.kind == safeKind ? receiver : null;
			cur = receiver;
		}
		return null;
	}

}

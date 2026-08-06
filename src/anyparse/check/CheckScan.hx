package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;
import haxe.ds.ObjectMap;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.RefactorSupport.ChainTypeContext;

/**
 * Shared scan helpers for the `run` / `fix` paths of the analysis checks.
 * A check parses INDEPENDENTLY in `run` and in `fix` — the platform's
 * thread-safety invariant forbids any shared mutable state or cache between
 * the two calls — so these are PURE static helpers taking the `(plugin,
 * source)` a check already holds. Not a base class (`Check` is an interface),
 * not a cache.
 */
@:nullSafety(Strict)
final class CheckScan {

	/** A binary logical node has exactly [left, right] children. */
	private static inline final BINARY_CHILD_COUNT: Int = 2;

	/** The shortest disjunction that can strand a narrowing: with two operands the first operand's fact always reaches the second. */
	private static inline final STRANDABLE_CHAIN_LENGTH: Int = 3;

	/** The grammar's `using` declaration kind, spelled literally (see `hasUsingModule`). */
	public static inline final USING_DECL_KIND: String = 'UsingDecl';

	/** The class-body member kinds a method declaration projects as — a plain method and a `final` one. */
	public static final METHOD_KINDS: Array<String> = ['FnMember', 'FinalModifiedMember'];

	/** The read-accessor method-name prefix; its length also slices the property name off. */
	public static inline final GET_PREFIX: String = 'get_';

	/** The write-accessor method-name prefix (same length as `GET_PREFIX`, which slices both). */
	public static inline final SET_PREFIX: String = 'set_';

	/** The node kinds a string expression projects as — the hosts whose `Literal` children are interpolation fragments. */
	public static final STRING_EXPR_KINDS: Array<String> = ['SingleStringExpr', 'DoubleStringExpr'];

	/** The static-text child kind inside an interpolated string expression. */
	public static inline final STRING_FRAGMENT_KIND: String = 'Literal';

	/** The top-level declaration kinds a `using` insert anchors after — the file's package / import / using header. */
	private static final USING_ANCHOR_KINDS: Array<String> = [
		'PackageDecl',
		'ImportDecl',
		'ImportAliasDecl',
		'ImportAliasInDecl',
		'ImportWildDecl',
		USING_DECL_KIND
	];

	private function new() {}

	/**
	 * Parse `source` with `plugin`, or null on any parse failure — the tolerant
	 * parse every check's `run` / `fix` opens with (`Check` forbids throwing on
	 * unparseable input, so both failure modes collapse to null).
	 */
	public static function parseOrNull(plugin: GrammarPlugin, source: String): Null<QueryNode> {
		return try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
	}

	/**
	 * `parseOrNull` over the TYPE-REFERENCE projection (`GrammarPlugin.parseFileTypeRefs`) — the
	 * parallel tree that surfaces the annotation positions the default projection drops into trivia.
	 * Same tolerance contract; a check reads one or the other, never both from one parse.
	 */
	public static function parseTypeRefsOrNull(plugin: GrammarPlugin, source: String): Null<QueryNode> {
		return try plugin.parseFileTypeRefs(source) catch (exception: ParseError) null catch (exception: Exception) null;
	}

	/**
	 * `parseOrNull` over the BRANCH-AWARE projection (`GrammarPlugin.projectBranchAware`) — the
	 * plain tree with every statement-position conditional-compilation region regrouped into one
	 * `CondBranch` statement list per branch, so a statement-list check reads N lists instead of
	 * one flat run of every branch's statements. Same tolerance contract as `parseOrNull`; a
	 * check reads one projection or the other, never both from one parse.
	 *
	 * The plain parse and the projection are two calls on purpose: the plugin's own caching
	 * decorator memoizes each, so the pair costs ONE parse plus one projection per source no
	 * matter how many checks opt in.
	 */
	public static function parseBranchAwareOrNull(plugin: GrammarPlugin, source: String): Null<QueryNode> {
		return try {
			final tree: QueryNode = plugin.parseFile(source);
			plugin.projectBranchAware(tree, source);
		} catch (exception: ParseError) null catch (exception: Exception) null;
	}

	/**
	 * The autofix skeleton shared by every span-indexed `fix`: parse `source`,
	 * index its `indexKinds` nodes by `from:to`, then for each violation with a
	 * span re-find the flagged node and let `produce` build its edit (null to
	 * skip that one). Returns the batched edits (empty when `source` does not
	 * parse). `produce` closes over the check's own seams and `source`; the
	 * helper owns only the parse + span-lookup boilerplate.
	 */
	public static function applyBySpan(
		plugin: GrammarPlugin, source: String, violations: Array<Violation>, indexKinds: Array<String>,
		produce: (node:QueryNode, span:Span) -> Null<{ span: Span, text: String }>
	): Array<{ span: Span, text: String }> {
		final tree: Null<QueryNode> = parseOrNull(plugin, source);
		if (tree == null) return [];
		final byKey: Map<String, QueryNode> = [];
		RefactorSupport.indexNodesByKind(tree, indexKinds, byKey);
		return collectSpanEdits(violations, byKey, produce);
	}

	/**
	 * The null-comparison flavour of `simplifyConditionFixes`: `!=` is always-true,
	 * `==` always-false. Shared verbatim by `dead-null-guard` and
	 * `unnecessary-null-check`, whose `fix` differ only in how `run` proved the
	 * operand non-null — the rewrite is identical.
	 */
	public static function simplifyNullComparisonFixes(
		plugin: GrammarPlugin, source: String, violations: Array<Violation>
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final eq: Null<String> = shape.eqKind;
		final notEq: Null<String> = shape.notEqKind;
		if (eq == null || notEq == null) return [];
		final ne: String = notEq;
		return simplifyConditionFixes(plugin, source, violations, [eq, notEq], node -> node.kind == ne);
	}

	/**
	 * Rewrite each flagged provably-constant boolean comparison, dropping it where a
	 * safe span edit exists and refusing (leaving it a finding) everywhere else. The
	 * flagged node is recovered by span (its kind is in `flaggedKinds`); `alwaysTrueOf`
	 * gives its constant polarity (an `x != null` / `x is T` is always-true, an
	 * `x == null` always-false). Two rewrite shapes only:
	 *
	 *  - (a) the SOLE condition of a no-`else` `if` statement — an always-true one
	 *    unwraps the body, an always-false one deletes the whole `if` (both refuse
	 *    when a comment sits in the removed region, never silently dropping it);
	 *  - (b) a direct operand of a homogeneous same-operator logical chain — an
	 *    always-true conjunct is dropped from `&&`, an always-false disjunct from
	 *    `||` (both identities). A mixed `&&`/`||` nesting, a parenthesised operand,
	 *    a ternary / other expression position, or an `else`-bearing `if` all refuse.
	 *
	 * Edits are de-overlapped (two conjuncts flagged in one chain, or a dead `if`
	 * inside a dead `if`) so the batch applies cleanly; the deferred ones converge on
	 * a later `--fix` pass. The result is re-emitted through the canonical writer by
	 * the caller, which re-indents an unwrapped body and validates the splice.
	 */
	public static function simplifyConditionFixes(
		plugin: GrammarPlugin, source: String, violations: Array<Violation>, flaggedKinds: Array<String>, alwaysTrueOf: (QueryNode) -> Bool
	): Array<{ span: Span, text: String }> {
		final tree: Null<QueryNode> = parseOrNull(plugin, source);
		if (tree == null) return [];
		final root: QueryNode = tree;
		final shape: RefShape = plugin.refShape();
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		final seams: CondSimplifySeams = {
			ifKinds: shape.ifStatementKinds ?? [],
			andKind: shape.logicalAndKind ?? '',
			orKind: shape.logicalOrKind ?? '',
			parenKind: shape.parenKind ?? '',
			blockKinds: support != null ? support.blockKinds() : []
		};
		final parents: ObjectMap<QueryNode, QueryNode> = new ObjectMap();
		fillParents(root, parents);
		final byKey: Map<String, QueryNode> = [];
		RefactorSupport.indexNodesByKind(root, flaggedKinds, byKey);
		return nonOverlappingEdits(
			collectSpanEdits(violations, byKey, (node, _) -> conditionEdit(node, alwaysTrueOf(node), parents, source, seams))
		);
	}

	/**
	 * The source text of a negation of `cond`, comment-preserving — the shared
	 * condition-inverting engine of `loop-guard`, `guard-continue` and `guard-return`.
	 *
	 * When a grammar `support` is passed AND the condition span holds no comment marker AND the
	 * condition does not strand a null-safety narrowing (`narrowingStranded`), the negation is
	 * delegated to `BooleanLogicSupport.negateCondition`: De Morgan pushed inward
	 * (`a && b` → `!a || !b`) order-safely — ordered comparisons stay wrapped `!(a < b)` unless
	 * `typeNominalOf` proves both operands totally ordered. The comment scan is
	 * STRING-LITERAL-BLIND: a `//` or `/*` inside a string operand conservatively forces the
	 * fallback (a verbatim `!(cond)` wrap — correct output, just not De-Morganed). With no
	 * `support`, a comment in the condition span, or a stranded narrowing, the text engine below is
	 * used, in three shapes, in order:
	 *
	 *  - a leading logical-not is STRIPPED (`!e` → `e`), unwrapping one redundant paren
	 *    (`!(a && b)` → `a && b`, `!!x` → `!x`) — the inner source verbatim;
	 *  - an `==` / `!=` is FLIPPED (`a == b` → `a != b` and back), NaN-safe (IEEE
	 *    `NaN == x` is false and `NaN != x` true) — UNLESS a comment sits in the operator
	 *    gap, which the flip would drop, so it falls through to the verbatim wrap;
	 *  - everything else (ordered comparisons `< <= > >=`, `&& || ?? ?:`, a call, …) is
	 *    wrapped `!(<cond>)` VERBATIM — the only sound negation for `<` / `>=` (they DIFFER
	 *    from their flips when an operand is a NaN or a `null`) and comment-preserving for every
	 *    shape. A bare atomic (`atomicKinds`) drops the parens (`!cond`); the wrap is always fully
	 *    parenthesised, so a low-precedence body (`a ?? b`, `c ? t : e`) negates correctly.
	 *
	 * For every standard type and normal abstract this is exactly `!(cond)`. The flip and
	 * strip assume standard boolean algebra, so they are UNSOUND only for the pathological
	 * case of a Haxe abstract that overloads `==` / `!=` non-complementarily or `!`
	 * non-involutively (`@:op`) — where `a != b` need not be `!(a == b)`; the
	 * always-parenthesised wrap is the sound form there. This edge is shared with `loop-guard`.
	 */
	public static function negateConditionText(
		cond: QueryNode, source: String, seams: NegationSeams, ?support: BooleanLogicSupport, ?typeNominalOf: (QueryNode) -> Null<String>,
		?slotKind: String
	): String {
		final cs: Null<Span> = cond.span;
		if (cs == null) return '';
		if (support != null && !hasCommentMarker(source, cs.from, cs.to) && !narrowingStranded(cond, seams))
			return support.negateCondition(cond, source, typeNominalOf, slotKind);
		final inner: Null<QueryNode> = notUnwrapNode(cond, seams);
		if (inner != null) {
			final innerSpan: Null<Span> = inner.span;
			// The STRIP arm is the ONE fallback shape that can bind looser than the slot it lands in
			// (`!(a || b)` hands back `a || b` verbatim); the flip and the wrap below both bind tighter
			// than `&&`. The `&&` slot is also the only one `RefShape` describes — via the same
			// `andLowerPrecedenceKinds` list `collapsible-if` merges with, which must stay in step with
			// the seam engine's own `slotPrecedence` answering this question for the De Morgan tier.
			if (innerSpan != null) {
				final text: String = source.substring(innerSpan.from, innerSpan.to);
				final loose: Bool = slotKind != null && slotKind == seams.andKind && seams.andLowerPrecedenceKinds.contains(inner.kind);
				return loose ? '($text)' : text;
			}
		}
		final flipped: Null<String> = eqFlipText(cond, source, seams);
		if (flipped != null) return flipped;
		final src: String = source.substring(cs.from, cs.to);
		return seams.atomicKinds.contains(cond.kind) ? '!$src' : '!($src)';
	}

	/**
	 * Whether inverting `cond` is worth doing at all — true unless the negation engine had to
	 * DECLINE a rewrite it knows how to perform. The three inverting checks gate on this BEFORE
	 * they flag: their purpose is to make a block read better by shedding a nesting level, and an
	 * inversion that has to keep `!(a < b)` wrapped — because the flip could not be proven free of
	 * both NaN and `null` — trades that nesting for a negation the positive form did not need.
	 *
	 * A wrap the engine could never avoid (`!(a is B)`, `!(a ?? b)`) is NOT a decline: that IS
	 * the canonical negation, and such a site still inverts. The text fallback tier (no grammar
	 * `support`, a comment in the condition, or a stranded null-safety narrowing) has no flip to
	 * decline, so it keeps emitting exactly what it always did.
	 */
	public static function negationIsClean(
		cond: QueryNode, source: String, seams: NegationSeams, ?support: BooleanLogicSupport, ?typeNominalOf: (QueryNode) -> Null<String>
	): Bool {
		final cs: Null<Span> = cond.span;
		if (cs == null) return false;
		// Only the De Morgan tier can decline anything — the text fallback has no flip to refuse,
		// so its verbatim wrap is the shape it always emitted and the site still inverts.
		return support == null || hasCommentMarker(source, cs.from, cs.to) || narrowingStranded(cond, seams)
			|| !support.negateConditionDeclinesFlip(cond, source, typeNominalOf);
	}

	/**
	 * The operand-type probe `negateConditionText` hands to a `BooleanLogicSupport` so it may
	 * flip an ordered comparison instead of wrapping it `!(…)` — see
	 * `BooleanLogicSupport.negateCondition`. Answers a node's declared type nominal through the
	 * run's resolution scope, or null for anything it cannot pin, which keeps the wrap.
	 *
	 * The probe is `RefactorSupport.expressionTypeNominal`, run in its DEEP mode — the
	 * `ChainTypeContext` built below. On top of the plain identifier / field-path answer it
	 * resolves four further shapes:
	 *
	 *  - a METHOD CALL's return nominal, through its receiver chain (`chain.indexOf(x)` → `Int`);
	 *  - a `for` BINDER's type, read off the iterable's element type parameter — the binder carries
	 *    no `:Type`, so it has no `declaredTypes` entry of its own;
	 *  - a TABLED stdlib static call's return (`RefShape.staticMethodReturns`), which is what makes
	 *    the binder arm reach `for (key in Reflect.fields(o))`;
	 *  - a generic member's TYPE ARGUMENT, so `b.payload.text` on a `b:Box<Item>` reaches `Item`'s
	 *    member instead of stopping at the verbatim parameter name `T`.
	 *
	 * All four are added PROOF only: every extra resolution can turn a conservative `!(a < b)`
	 * wrap into a licensed flip, never the reverse, so the unproven → refuse default every
	 * guard-family consumer relies on is untouched.
	 *
	 * The deep mode stays an OPT-IN parameter rather than a widening of
	 * `RefactorSupport.valueTypeNominal` because its other consumers read a resolved nominal as a
	 * licence to ACT, so each has to decide for itself. `map-keys-lookup` has not opted in;
	 * `prefer-static-extension` HAS, deliberately — see `PreferStaticExtension.receiverNominal` for
	 * why each deep arm is type-CORRECT and fail-closed rather than merely more permissive, which is
	 * the bar an arm must clear before an acting consumer may take it.
	 *
	 * Null when the grammar carries no type information at all: the caller then passes nothing
	 * and every ordered comparison stays wrapped, exactly as before this seam existed.
	 */
	public static function typeNominalResolver(
		source: String, plugin: GrammarPlugin, tree: QueryNode, file: String, ?index: SymbolIndex
	): Null<(QueryNode) -> Null<String>> {
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		if (provider == null) return null;
		final declaredTypes: Map<Int, String> = provider.declaredTypes(source);
		final shape: RefShape = plugin.refShape();
		// The resolution index sees the std + configured libraries, so a member type such as
		// `Array.length` resolves; the report index alone would stop at the project boundary.
		final resolved: Null<SymbolIndex> = RefactorSupport.resolutionIndexOf(plugin) ?? index;
		final chain: ChainTypeContext = { declaredTypeSources: provider.declaredTypeSources(source), source: source };
		return node -> RefactorSupport.expressionTypeNominal(node, tree, shape, declaredTypes, resolved, file, chain);
	}

	/**
	 * The `NegationSeams` `shape` exposes: the kinds `negateConditionText` strips, unwraps
	 * and flips, the atomic-expression kinds that take a bare `!` rather than `!(…)`, and the
	 * logical / identifier kinds the stranded-narrowing gate walks. Built here rather than at
	 * each call site because the three inverting checks (`guard-return`, `guard-continue`,
	 * `loop-guard`) read exactly the same seams, and a field added to `NegationSeams` must not
	 * have to be threaded through three identical literals.
	 */
	public static function negationSeams(shape: RefShape): NegationSeams {
		return {
			notKind: shape.notKind,
			parenKind: shape.parenKind,
			eqKind: shape.eqKind,
			notEqKind: shape.notEqKind,
			atomicKinds: [
				for (k in [
					(shape.identKind: Null<String>),
					shape.callKind,
					shape.fieldAccessKind,
					shape.forceFieldAccessKind,
					shape.nullSafeAccessKind,
					shape.indexAccessKind,
					shape.newExprKind,
					shape.parenKind,
					shape.boolLitKind
				]) if (k != null) k
			],
			andKind: shape.logicalAndKind,
			orKind: shape.logicalOrKind,
			identKind: shape.identKind,
			andLowerPrecedenceKinds: shape.andLowerPrecedenceKinds ?? []
		};
	}

	/**
	 * Whether De-Morganing `cond` would strand a Haxe null-safety narrowing — the gate every
	 * consumer of `negateConditionText` needs, and which that engine applies itself; exposed
	 * because a check may want to know BEFORE it decides to flag at all (`guard-return` refuses
	 * an already multi-line condition on this path, whose verbatim wrap would read worse than
	 * the branch it replaces).
	 *
	 * An `&&` chain negates into a flat left-associative `||` chain, and Haxe carries a
	 * narrowing fact into a later `||` operand from the chain's FIRST operand ONLY
	 * (measured on the compiler: in `a == null || b == null || p(a.length, b.length)`
	 * the `b` narrowing does not reach operand 3, while the `a` one does). The scan is
	 * syntactic and conservative - no type information: a negated `&&` chain strands
	 * when an operand at index 2 or later (0-based) shares a plain identifier with a
	 * preceding operand OTHER than the first. A `!` node is not descended: negating it
	 * STRIPS the `!` and re-emits its operand verbatim, restructuring nothing. A grammar
	 * with no `andKind` seam never strands.
	 */
	public static function narrowingStranded(cond: QueryNode, seams: NegationSeams): Bool {
		final andKind: Null<String> = seams.andKind;
		if (andKind == null) return false;
		if (cond.kind == seams.parenKind) return cond.children.length == 1 && narrowingStranded(cond.children[0], seams);
		if (cond.kind == seams.notKind) return false;
		if (cond.kind != andKind && cond.kind != seams.orKind) return false;
		final operands: Array<QueryNode> = [];
		flattenChain(cond, cond.kind, seams.parenKind, operands);
		if (cond.kind == andKind && chainStrands(operands, seams)) return true;
		for (operand in operands) if (narrowingStranded(operand, seams)) return true;
		return false;
	}

	/**
	 * Whether a top-level `using <module>;` is already present — then the module's
	 * extension methods resolve without inserting one. `module` may be QUALIFIED
	 * (`pkg.Lambda`), in which case only an exact match counts; a SIMPLE `module`
	 * (`Lambda`) also matches a qualified declaration ending in it (`pkg.Lambda`),
	 * since both bring the same module into scope. Shared by `prefer-find` and
	 * `prefer-static-extension`.
	 *
	 * CAVEAT on that simple-name match: the index models no packages, so a `using
	 * other.pkg.Lambda` of an UNRELATED project-local module sharing the simple name reads
	 * as present and suppresses the insert. It errs toward not inserting — a loud compile
	 * error rather than a silent behaviour change — and a stdlib module (the configured
	 * default) has no same-named sibling to collide with.
	 *
	 * The declaration kind is spelled literally (`USING_DECL_KIND`): `RefShape` exposes no
	 * using-declaration seam, so a grammar naming it differently reads as having no
	 * `using` at all — which only ever causes a redundant insert, never a wrong one.
	 */
	public static function hasUsingModule(tree: QueryNode, module: String): Bool {
		final simple: Bool = module.indexOf('.') == -1;
		for (child in tree.children) if (child.kind == USING_DECL_KIND) {
			final name: Null<String> = child.name;
			if (name != null && (name == module || (simple && StringTools.endsWith(name, '.$module')))) return true;
		}
		return false;
	}

	/**
	 * A ZERO-WIDTH edit inserting `using <module>;` into `tree`. The insert companion of
	 * `hasUsingModule`; the caller applies it only after deciding at least one rewrite needs
	 * the module in scope.
	 *
	 * The position is a CORRECTNESS choice, not cosmetics: Haxe resolves static extensions in
	 * REVERSE declaration order, so the LAST `using` wins. Inserting after an existing `using`
	 * run would give the new module top priority and silently re-target every same-named
	 * extension call the file already makes through an earlier `using`. So the insert goes
	 * ABOVE the FIRST existing `using` — lowest priority, no existing call disturbed — and
	 * falls back to after the last package / import declaration, or the file head with a
	 * trailing blank line, only when the file declares no `using` at all.
	 */
	public static function usingInsertEdit(tree: QueryNode, module: String): { span: Span, text: String } {
		var anchor: Null<Span> = null;
		for (child in tree.children) {
			if (child.kind == USING_DECL_KIND) {
				final first: Null<Span> = child.span;
				if (first != null) return { span: new Span(first.from, first.from), text: 'using $module;\n' };
			}
			if (USING_ANCHOR_KINDS.contains(child.kind)) {
				final span: Null<Span> = child.span;
				if (span != null) anchor = span;
			}
		}
		final at: Null<Span> = anchor;
		return at == null ? { span: new Span(0, 0), text: 'using $module;\n\n' } : {
			span: new Span(at.to, at.to),
			text: '\nusing $module;'
		};
	}

	/**
	 * Whether a `using` OTHER than `module` in the same file could also supply `method` — the
	 * gate every extension-method rewrite needs before it emits a `<recv>.<method>(…)` call.
	 *
	 * Haxe resolves static extensions in REVERSE declaration order, so a second module declaring
	 * the same name decides where the rewritten call lands. Two rules depend on that: writing an
	 * explicit `Module.m(x)` in such a file may be deliberate disambiguation the rewrite would
	 * undo, and a `using` INSERTED below an existing run (see `usingInsertEdit`) loses to it. A
	 * module naming the same type as `module` is skipped; for the rest a known extension table
	 * decides, and without one `symbols` must PROVE the module declares no such member. Every
	 * doubt — an unknown module with no index, or one the index cannot resolve — counts as a
	 * conflict, so the caller refuses rather than emits a silently retargeted call.
	 *
	 * The verdict depends only on the `(module, method)` pair while a file repeats it across
	 * every site, and each miss costs a whole-index member-closure query, so `memo` carries it
	 * for the caller's run. Pass a fresh map per file — a `using` set is per-file state.
	 */
	public static function conflictingUsing(
		usings: Array<String>, module: String, method: String, plugin: GrammarPlugin, symbols: () -> Null<SymbolIndex>,
		memo: Map<String, Bool>
	): Bool {
		final key: String = '$module:$method';
		final cached: Null<Bool> = memo[key];
		if (cached != null) return cached;
		final verdict: Bool = conflictScan(usings, module, method, plugin, symbols);
		memo[key] = verdict;
		return verdict;
	}

	/** The unmemoised body of `conflictingUsing` — one pass over the file's other `using` declarations. */
	private static function conflictScan(
		usings: Array<String>, module: String, method: String, plugin: GrammarPlugin, symbols: () -> Null<SymbolIndex>
	): Bool {
		final simple: String = simpleModuleName(module);
		for (path in usings) if (path != module && simpleModuleName(path) != simple) {
			final known: Null<Array<String>> = plugin.knownExtensionMethods(path);
			if (known != null) {
				if (known.contains(method)) return true;
				continue;
			}
			final index: Null<SymbolIndex> = symbols();
			if (index == null || !index.typeProvablyLacksMember(simpleModuleName(path), method)) return true;
		}
		return false;
	}

	/** The last dot-segment of a module path — the name a call site spells (`utils.TextUtil` -> `TextUtil`); `RefactorSupport.lastSegment` under a name that says which question the check layer is asking. */
	public static inline function simpleModuleName(path: String): String {
		return RefactorSupport.lastSegment(path);
	}

	/** The module paths of every top-level `using` declaration in `tree` — the read side of `hasUsingModule`. */
	public static function usingModules(tree: QueryNode): Array<String> {
		final out: Array<String> = [];
		for (child in tree.children) if (child.kind == USING_DECL_KIND) {
			final name: Null<String> = child.name;
			if (name != null) out.push(name);
		}
		return out;
	}

	/**
	 * Whether `[from, to)` of `source` holds a `//` or `/*` comment marker — the check
	 * layer's entry point to `RefactorSupport.hasCommentMarker`, which owns the scan and
	 * the recorded per-caller argument for why it stays string-blind.
	 *
	 * The conservative "don't delete a comment" guard: for every consumer but the negation
	 * pair below, a marker found inside a string literal only ever REFUSES a fix, never
	 * deletes code. `negateConditionText` / `negationIsClean` read it as a tier selector
	 * instead — see the primitive's doc before changing anything here.
	 */
	public static inline function hasCommentMarker(source: String, from: Int, to: Int): Bool {
		return RefactorSupport.hasCommentMarker(source, from, to);
	}

	/**
	 * The node kinds whose presence in a subtree makes a once-vs-twice evaluation
	 * rewrite unsafe: every binding-write (`writeParentKinds`), plus `callKind` and
	 * `newExprKind` when the grammar exposes them. Shared by the checks that collapse a
	 * repeated operand (`prefer-null-coalescing`, `prefer-safe-nav-comparison`) — the
	 * gate is SYNTACTIC, so it sees a call or a construction but not an implicit
	 * property getter behind a plain field read.
	 */
	public static function mutationKinds(shape: RefShape): Array<String> {
		final kinds: Array<String> = shape.writeParentKinds.copy();
		final callKind: Null<String> = shape.callKind;
		if (callKind != null) kinds.push(callKind);
		final newExprKind: Null<String> = shape.newExprKind;
		if (newExprKind != null) kinds.push(newExprKind);
		return kinds;
	}

	/**
	 * Whether `kind` is a class-body node whose direct children carry the members —
	 * `ClassDecl` (a plain class), `ClassForm` (the inner form of a `final` class
	 * under a `FinalDecl` wrapper), or `AbstractClassDecl` (an `abstract class`).
	 * Shared by the class-walking checks (PreferInline / TrivialGetter / UnusedPrivate / Naming) so their walkers agree on
	 * the set; note PreferInline and TrivialGetter REWRITE members of whatever this admits — widen it only with their fix
	 * gates in mind.
	 */
	public static inline function isClassBodyKind(kind: String): Bool {
		return kind == 'ClassDecl' || kind == 'ClassForm' || kind == 'AbstractClassDecl';
	}

	/**
	 * Every class-body node in `root`'s subtree (`isClassBodyKind`), pre-order —
	 * the collector shared by PreferInline and TrivialGetter (Naming / UnusedPrivate run their own stateful walks over the same predicate).
	 */
	public static function classBodies(root: QueryNode): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		collectClassBodies(root, out);
		return out;
	}

	/**
	 * The whitespace-normalized view of `[from, to)`: every run of spaces / tabs /
	 * newlines collapsed to a single space with the ends trimmed, plus the count of
	 * non-whitespace characters. The shared text-identity metric of `duplicate-code`
	 * (which hashes statement norms to find clones and gates a run on its non-whitespace
	 * size), `extract-repeated-expression` (which buckets equal expressions) and
	 * `tail-merge` (which compares a branch tail against the shared fall-through run). Deliberately NOT string-literal-aware: whitespace INSIDE a literal collapses
	 * too, so `f("a  b")` and `f("a b")` normalize equal — a consumer needing exact token
	 * identity pairs this with a structural comparison rather than relying on it alone.
	 */
	public static function normalizeSpan(source: String, from: Int, to: Int): NormalizedSpan {
		final buf: StringBuf = new StringBuf();
		var nonWs: Int = 0;
		var pendingSpace: Bool = false;
		for (i in from ... to) {
			final c: Int = StringTools.fastCodeAt(source, i);
			if (c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code) {
				pendingSpace = true;
			} else {
				if (pendingSpace && nonWs > 0) buf.addChar(' '.code);
				pendingSpace = false;
				buf.addChar(c);
				nonWs++;
			}
		}
		return { norm: buf.toString(), nonWs: nonWs };
	}

	/**
	 * Iterate `violations`, recover each flagged node from `byKey` by its `from:to`
	 * span, and collect the non-null edits `produce` builds — the span-lookup loop
	 * shared by `applyBySpan` and `simplifyConditionFixes`.
	 */
	private static function collectSpanEdits(
		violations: Array<Violation>, byKey: Map<String, QueryNode>,
		produce: (node:QueryNode, span:Span) -> Null<{ span: Span, text: String }>
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final node: Null<QueryNode> = byKey['${span.from}:${span.to}'];
			if (node == null) continue;
			final edit: Null<{ span: Span, text: String }> = produce(node, span);
			if (edit != null) edits.push(edit);
		}
		return edits;
	}

	/**
	 * The edit for one flagged constant comparison `node`, or null (refuse). Shape (a)
	 * when `node` is the sole condition of a no-`else` `if`; shape (b) when it is a
	 * direct operand of the matching homogeneous logical chain (`&&` for always-true,
	 * `||` for always-false); refuse otherwise.
	 */
	private static function conditionEdit(
		node: QueryNode, alwaysTrue: Bool, parents: ObjectMap<QueryNode, QueryNode>, source: String, seams: CondSimplifySeams
	): Null<{ span: Span, text: String }> {
		final parent: Null<QueryNode> = parents.get(node);
		if (parent == null) return null;
		if (seams.ifKinds.contains(parent.kind) && parent.children.length == 2 && parent.children[0] == node)
			return ifShapeEdit(parent, alwaysTrue, parents, source, seams);
		final wantKind: String = alwaysTrue ? seams.andKind : seams.orKind;
		return wantKind != '' && parent.kind == wantKind && homogeneousChain(parent, wantKind, parents, seams)
			? dropOperandEdit(parent, node, source)
			: null;
	}

	/**
	 * Shape (a): `ifNode` is a no-`else` `if` whose sole condition is a proven
	 * constant. Always-true replaces the whole `if` with its body source (a bare
	 * block keeps its braces, preserving scope); always-false deletes the `if`
	 * (line-extended when it sits in a statement list, else `{}` so an enclosing
	 * branch is not orphaned). Refuses when a comment sits in any removed region.
	 */
	private static function ifShapeEdit(
		ifNode: QueryNode, alwaysTrue: Bool, parents: ObjectMap<QueryNode, QueryNode>, source: String, seams: CondSimplifySeams
	): Null<{ span: Span, text: String }> {
		final ns: Null<Span> = ifNode.span;
		final body: QueryNode = ifNode.children[1];
		final bs: Null<Span> = body.span;
		if (ns == null || bs == null) return null;
		// An always-true guard keeps only the body — refuse if a comment sits in the removed
		// `if (…)` header or trailing region (comments inside the body are preserved).
		if (alwaysTrue) return hasCommentMarker(source, ns.from, bs.from) || hasCommentMarker(source, bs.to, ns.to) ? null : {
			span: ns,
			text: source.substring(bs.from, bs.to)
		};
		if (hasCommentMarker(source, ns.from, ns.to)) return null;
		final ifParent: Null<QueryNode> = parents.get(ifNode);
		final inBlock: Bool = ifParent != null && seams.blockKinds.contains(ifParent.kind);
		return inBlock ? { span: RefactorSupport.lineExtendedSpan(source, ns), text: '' } : { span: ns, text: '{}' };
	}

	/**
	 * Shape (b): drop `operand` (one of the two children of the binary logical
	 * `chain` node) together with its adjacent operator — the right operand deletes
	 * `[left.to, right.to)` (` && x`), the left deletes `[left.from, right.from)`
	 * (`x && `). The surviving operand's source (its parentheses included) is
	 * untouched. Refuses when a comment sits in the removed operator / operand region.
	 */
	private static function dropOperandEdit(chain: QueryNode, operand: QueryNode, source: String): Null<{ span: Span, text: String }> {
		if (chain.children.length != 2) return null;
		final left: QueryNode = chain.children[0];
		final right: QueryNode = chain.children[1];
		final ls: Null<Span> = left.span;
		final rs: Null<Span> = right.span;
		if (ls == null || rs == null) return null;
		// Drop the operand together with its adjacent operator: the right operand deletes
		// `[left.to, right.to)` (` && x`), the left `[left.from, right.from)` (`x && `).
		final drop: Null<Span> = operand == right ? new Span(ls.to, rs.to) : operand == left ? new Span(ls.from, rs.from) : null;
		return drop == null || hasCommentMarker(source, drop.from, drop.to) ? null : { span: drop, text: '' };
	}

	/**
	 * Whether every logical ancestor of `node` up to the first non-logical boundary is
	 * the SAME operator as `wantKind` — a pure `&&` (or pure `||`) chain. A different
	 * logical operator (mixed `&&`/`||`) or a parenthesised wrap returns false, so the
	 * conservative drop fires only inside a homogeneous chain.
	 */
	private static function homogeneousChain(
		node: QueryNode, wantKind: String, parents: ObjectMap<QueryNode, QueryNode>, seams: CondSimplifySeams
	): Bool {
		var cur: QueryNode = node;
		while (true) {
			final p: Null<QueryNode> = parents.get(cur);
			if (p == null) return true;
			if (p.kind == seams.andKind || p.kind == seams.orKind) {
				if (p.kind != wantKind) return false;
				cur = p;
			} else
				return p.kind != seams.parenKind;
		}
	}

	/** Record each node's parent, so a flagged node can be classified by its enclosing context. */
	private static function fillParents(node: QueryNode, out: ObjectMap<QueryNode, QueryNode>): Void {
		for (c in node.children) {
			out.set(c, node);
			fillParents(c, out);
		}
	}

	/**
	 * Keep a maximal non-overlapping subset of `edits` (earliest span first) so the
	 * `RefactorSupport.applyEdits` no-overlap contract holds — two conjuncts flagged
	 * in one chain, or a dead `if` nested in a dead `if`, would otherwise splice
	 * overlapping deletions. The dropped edits converge on a later `--fix` pass.
	 */
	private static function nonOverlappingEdits(edits: Array<{ span: Span, text: String }>): Array<{ span: Span, text: String }> {
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> a.span.from - b.span.from);
		final kept: Array<{ span: Span, text: String }> = [];
		var lastTo: Int = -1;
		for (e in sorted) if (e.span.from >= lastTo) {
			kept.push(e);
			lastTo = e.span.to;
		}
		return kept;
	}

	/**
	 * The `!e` -> `e` STRIP arm of `negateConditionText`: unwraps a leading logical-not
	 * (and one redundant paren under it), returning the inner NODE — the caller reads its
	 * source and asks `slotWrap` whether the slot it lands in needs a parenthesis pair.
	 * Null when `cond` is not a not-node.
	 */
	private static function notUnwrapNode(cond: QueryNode, seams: NegationSeams): Null<QueryNode> {
		final notKind: Null<String> = seams.notKind;
		if (notKind == null || cond.kind != notKind || cond.children.length < 1) return null;
		final inner: QueryNode = cond.children[0];
		final parenKind: Null<String> = seams.parenKind;
		return parenKind != null && inner.kind == parenKind && inner.children.length == 1 ? inner.children[0] : inner;
	}


	/**
	 * The `==` / `!=` FLIP arm of `negateConditionText`: rewrites a binary (in)equality
	 * to its complement operator (NaN-safe; see the caller's doc for the non-complementary
	 * `@:op` abstract caveat shared with `loop-guard`). Null when `cond` is not a binary
	 * (in)equality or a comment sits in the operator gap (the flip would drop it).
	 */
	private static function eqFlipText(cond: QueryNode, source: String, seams: NegationSeams): Null<String> {
		final eqKind: Null<String> = seams.eqKind;
		final notEqKind: Null<String> = seams.notEqKind;
		if (eqKind == null || notEqKind == null) return null;
		if ((cond.kind != eqKind && cond.kind != notEqKind) || cond.children.length != 2) return null;
		final l: Null<Span> = cond.children[0].span;
		final r: Null<Span> = cond.children[1].span;
		if (l != null && r != null && !hasCommentMarker(source, l.to, r.from)) {
			final op: String = cond.kind == eqKind ? ' != ' : ' == ';
			return source.substring(l.from, l.to) + op + source.substring(r.from, r.to);
		}
		return null;
	}

	/**
	 * Append the left-associative `kind` chain under `node` as a flat operand list.
	 * Parentheses are TRANSPARENT: the negation drops them and re-adds them only where
	 * precedence demands, so `a && (b && c)` emits the same flat `!a || !b || !c` as
	 * `a && b && c` and must flatten to the same three operands. Descending through a
	 * paren that wraps a DIFFERENT operator changes nothing — the inner node is pushed
	 * as the one operand the paren stood for, carrying the same identifiers.
	 */
	private static function flattenChain(node: QueryNode, kind: String, parenKind: Null<String>, out: Array<QueryNode>): Void {
		if (node.kind == parenKind && node.children.length == 1) {
			flattenChain(node.children[0], kind, parenKind, out);
			return;
		}
		if (node.kind != kind || node.children.length != BINARY_CHILD_COUNT) {
			out.push(node);
			return;
		}
		flattenChain(node.children[0], kind, parenKind, out);
		flattenChain(node.children[1], kind, parenKind, out);
	}

	/**
	 * Whether the disjunction `operands` negates into would strand a narrowing: some
	 * operand at index 2 or later shares an identifier with a preceding operand that is
	 * not the first (whose fact alone survives the `||` chain).
	 */
	private static function chainStrands(operands: Array<QueryNode>, seams: NegationSeams): Bool {
		if (operands.length < STRANDABLE_CHAIN_LENGTH) return false;
		final names: Array<Array<String>> = [for (operand in operands) identNames(operand, seams, [])];
		for (i in 2...operands.length) for (j in 1...i) for (name in names[i]) if (names[j].contains(name)) return true;
		return false;
	}

	/** Append every plain-identifier name in `node`'s subtree to `out` and return it. */
	private static function identNames(node: QueryNode, seams: NegationSeams, out: Array<String>): Array<String> {
		final name: Null<String> = node.name;
		if (node.kind == seams.identKind && name != null && name != '' && !out.contains(name)) out.push(name);
		for (child in node.children) identNames(child, seams, out);
		return out;
	}

	private static function collectClassBodies(node: QueryNode, out: Array<QueryNode>): Void {
		if (isClassBodyKind(node.kind)) out.push(node);
		for (child in node.children) collectClassBodies(child, out);
	}

	/**
	 * The end offsets of every doc block in `source` — the lookup a doc-anchor test needs,
	 * built ONCE per file. Comment boundaries come from the parser's own tokenizer, so a
	 * `/*` sequence inside a doc body (an escaped example) never fools the anchor — the trap
	 * a naive `lastIndexOf('/*')` hits.
	 */
	public static function docBlockEnds(source: String): Map<Int, Bool> {
		return [for (tok in RefactorSupport.collectCommentTokens(source)) if (RefactorSupport.isDocBlock(source, tok)) tok.to => true];
	}

	/**
	 * Whether a doc block's close sits at the last non-whitespace byte before `pos` — one
	 * immediately precedes the declaration anchored there. `docEnds` comes from
	 * `docBlockEnds`; a line comment or a plain `/* … *\/` block is absent from it, so
	 * neither reads as documentation.
	 */
	public static function hasDocBefore(source: String, docEnds: Map<Int, Bool>, pos: Int): Bool {
		var i: Int = pos - 1;
		while (i >= 0 && RefactorSupport.isSpace(StringTools.fastCodeAt(source, i))) i--;
		return i >= 0 && docEnds.exists(i + 1);
	}

	/**
	 * Whether `node` is a leading modifier / `@:meta` annotation — part of the sibling run
	 * that PRECEDES a declaration in the projection, rather than a declaration itself. The
	 * run's start is where a doc comment sits in source, so every doc-anchor walk needs it.
	 * `modifierKinds` is the grammar's modifier-kind set; a metadata node is recognised by
	 * its `@`-prefixed name, which no grammar spells differently.
	 */
	public static function isLeadingAnnotation(node: QueryNode, modifierKinds: Array<String>): Bool {
		final nm: Null<String> = node.name;
		if (nm != null && nm.length > 0 && StringTools.fastCodeAt(nm, 0) == '@'.code) return true;
		return modifierKinds.contains(node.kind);
	}

	/**
	 * The declared name of a type node — its own, or the name of the `containerKinds` child
	 * that carries it for a wrapped shape (a Haxe `final class`, whose name sits on the inner
	 * `ClassForm`). `'<anonymous>'` when neither has one.
	 */
	public static function typeDeclName(node: QueryNode, containerKinds: Array<String>): String {
		final own: Null<String> = node.name;
		if (own != null) return own;
		for (c in node.children) {
			final nm: Null<String> = c.name;
			if (nm != null && containerKinds.contains(c.kind)) return nm;
		}
		return '<anonymous>';
	}


	/**
	 * Every node kind that projects as a leading MODIFIER sibling before a declaration —
	 * the set `isLeadingAnnotation` tests a decl's preceding run against, so a check can
	 * find where a declaration's doc anchor starts.
	 *
	 * Assembled from `modifierOrderKinds` (the ordered core) plus the seams that sit
	 * outside it: the visibility pair and the four standalone modifier kinds. Deduped, so
	 * a grammar that already lists one in `modifierOrderKinds` contributes it once.
	 */
	public static function modifierKinds(shape: RefShape): Array<String> {
		final out: Array<String> = [for (m in shape.modifierOrderKinds ?? []) m];
		for (m in shape.visibilityModifierKinds ?? []) if (!out.contains(m)) out.push(m);
		for (kind in [
			shape.externModifierKind,
			shape.dynamicModifierKind,
			shape.macroModifierKind,
			shape.overrideModifierKind
		]) if (kind != null && !out.contains(kind)) out.push(kind);
		return out;
	}


	/**
	 * Whether `node`'s source STARTS with the grammar's `#if` directive — i.e. it is a
	 * conditional-compilation region, whatever kind the grammar happens to project it as.
	 *
	 * A kind test cannot do this job. The Haxe grammar carries a dozen conditional ctors, one per
	 * host position (`Conditional` for members and statements, `ConditionalExpr` in expression
	 * position, `ConditionalArgs` in an argument list, five `CondSplice*` forms for a region that
	 * straddles a block or switch boundary, ...), and `RefShape` names only the member one. An
	 * enumerated list would go stale the next time a position is added; the DIRECTIVE cannot,
	 * because every region opens with it by definition. The `#` first-char test keeps it to one
	 * comparison per node before any substring is taken.
	 */
	public static function opensConditionalRegion(node: QueryNode, source: String, condIf: Null<String>): Bool {
		final span: Null<Span> = node.span;
		if (condIf == null || span == null) return false;
		// The null checks stay in their own guard: strict null-safety carries a narrowing fact into
		// a later `||` operand only from the chain's FIRST operand.
		final from: Int = span.from;
		if (from >= source.length || StringTools.fastCodeAt(source, from) != '#'.code) return false;
		return source.substring(from, from + condIf.length) == condIf;
	}

	/**
	 * A function's declared RETURN annotation as written, or null when it declares none — the SOLE `typeAnnotationKinds`
	 * direct child that starts AFTER the parameter list's closing `)`. Position is the whole gate:
	 * a type-parameter CONSTRAINT (`function f<T:Foo>()`) projects the very same `Named` node in
	 * the very same child slot, always BEFORE the parameter list, so trusting "exactly one
	 * annotation child" made a constrained function with NO return type read as annotated `Foo`.
	 * The `)` is searched from the last parameter's end (or the function's start when it declares
	 * none), which puts a default value's parentheses behind the cursor; metadata projects as a
	 * sibling node outside the function span. A parameter's own annotation nests UNDER the
	 * parameter node, never as a direct child of the function, so it is never a candidate.
	 */
	public static function returnAnnotationText(fn: QueryNode, shape: RefShape, source: String): Null<String> {
		final fnSpan: Null<Span> = fn.span;
		if (fnSpan == null) return null;
		final paramsEnd: Int = lastParamEnd(fn, shape.paramKinds ?? []);
		final annotationKinds: Array<String> = shape.typeAnnotationKinds ?? [];
		var found: Null<Span> = null;
		var prevEnd: Int = fnSpan.from;
		for (child in fn.children) {
			final childSpan: Null<Span> = child.span;
			if (childSpan == null) return null;
			if (annotationKinds.contains(child.kind) && afterParamList(childSpan, prevEnd, paramsEnd, source)) {
				if (found != null) return null;
				found = childSpan;
			}
			prevEnd = childSpan.to;
		}
		return found == null ? null : source.substring(found.from, found.to);
	}

	/**
	 * The end offset of `fn`'s LAST declared parameter, or -1 when it declares none.
	 */
	private static function lastParamEnd(fn: QueryNode, paramKinds: Array<String>): Int {
		var end: Int = -1;
		for (child in fn.children) if (paramKinds.contains(child.kind)) {
			final paramSpan: Null<Span> = child.span;
			if (paramSpan != null && paramSpan.to > end) end = paramSpan.to;
		}
		return end;
	}

	/**
	 * Whether the annotation at `annotationSpan` sits AFTER the parameter list — the test that tells a
	 * RETURN type from a type-parameter CONSTRAINT, which projects the same node kind in the same child
	 * slot but always precedes the parameter list.
	 *
	 * With at least one declared parameter the answer is purely structural: every constraint precedes
	 * the first parameter, so starting after the LAST one settles it, whatever the header contains.
	 * A parameterless function has no such landmark, so the empty list's `)` is located in the text
	 * between the preceding sibling and the annotation. That window is guarded: a `)` may also sit
	 * inside a structural constraint (`<A:{ function n():Void; }, B:Foo>`), which is why the search
	 * starts at `prevEnd` rather than at the function's start, and a comment in the window refuses
	 * outright rather than letting a `)` inside it stand in for the parameter list.
	 */
	private static function afterParamList(annotationSpan: Span, prevEnd: Int, lastParamEnd: Int, source: String): Bool {
		if (lastParamEnd >= 0) return annotationSpan.from > lastParamEnd;
		if (CheckScan.hasCommentMarker(source, prevEnd, annotationSpan.from)) return false;
		final close: Int = source.indexOf(')', prevEnd);
		return close != -1 && close < annotationSpan.from;
	}


	/**
	 * The display width of `source[from, to)` with tabs expanded to `indentWidth` -- the
	 * column arithmetic every width-aware check needs. Pass a line's own `[lineStart, pos)`
	 * for the column `pos` sits at, or `[0, line.length)` for a whole line's width.
	 * Shared so `fold-adjacent-string-literals` and `prefer-case-guard` cannot drift on
	 * what a tab is worth.
	 */
	public static function displayColumn(source: String, from: Int, to: Int, indentWidth: Int): Int {
		var cols: Int = 0;
		for (i in from ... to) cols += StringTools.fastCodeAt(source, i) == '\t'.code ? indentWidth : 1;
		return cols;
	}

	/**
	 * The delete-the-whole-member edit for `node`: its modifier / metadata run (`declGroupSpan`,
	 * which needs the declaring `parent` for the sibling run) folded in, then the whole line
	 * (`lineExtendedSpan`), so no blank modifier line is left behind. The member's LEADING DOC
	 * COMMENT is kept — `unused-private`'s shape. Use `docDeletionEdit` to take the doc with it.
	 */
	public static inline function deletionEdit(
		source: String, node: QueryNode, parent: QueryNode, span: Span
	): { span: Span, text: String } {
		return { span: RefactorSupport.lineExtendedSpan(source, RefactorSupport.declGroupSpan(node, parent, span)), text: '' };
	}

	/**
	 * `deletionEdit` widened to swallow the member's leading DOC COMMENT (`docExtendedSpan`) as
	 * well, so deleting a documented method strands nothing — the shape `orphan-accessor` and
	 * `unused-public-member` delete with.
	 */
	public static inline function docDeletionEdit(
		source: String, node: QueryNode, parent: QueryNode, span: Span
	): { span: Span, text: String } {
		final group: Span = RefactorSupport.declGroupSpan(node, parent, span);
		return { span: RefactorSupport.lineExtendedSpan(source, RefactorSupport.docExtendedSpan(source, group)), text: '' };
	}

	/** The `<file>#<from>:<to>` key one declaration is memoised under between a check's `run` and its `fix`. */
	public static inline function spanKey(file: String, span: Span): String {
		return '$file#${span.from}:${span.to}';
	}

	/**
	 * Whether `branch` (an `if`'s then-branch, or any statement in branch position)
	 * unconditionally exits: a terminal statement directly, or a block whose LAST direct child
	 * is terminal. The shared reading of "this branch never falls through" — `redundant-else`
	 * de-nests on it, `redundant-replace-loop` reads a pre-loop guard with it.
	 */
	public static function branchAlwaysExits(branch: QueryNode, support: ControlFlowSupport): Bool {
		if (support.isTerminal(branch)) return true;
		if (!support.blockKinds().contains(branch.kind)) return false;
		final kids: Array<QueryNode> = branch.children;
		return kids.length > 0 && support.isTerminal(kids[kids.length - 1]);
	}

}

/**
 * The result of `CheckScan.normalizeSpan`: the whitespace-collapsed text of a source
 * range (`norm`) and its non-whitespace character count (`nonWs`, the content-gate metric).
 */
typedef NormalizedSpan = {
	final norm: String;
	final nonWs: Int;
};

/** The condition / logical / block seam kinds `simplifyConditionFixes` reads from the grammar. */
private typedef CondSimplifySeams = {
	final ifKinds: Array<String>;
	final andKind: String;
	final orKind: String;
	final parenKind: String;
	final blockKinds: Array<String>;
};

/**
 * The condition-kind seams `CheckScan.negateConditionText` reads to invert a condition:
 * the logical-not (`notKind`) it strips, the paren (`parenKind`) it unwraps, the
 * `==` / `!=` kinds (`eqKind` / `notEqKind`) it flips, the atomic-expression kinds
 * (`atomicKinds`) that take a bare `!` rather than `!(…)`, and the logical
 * (`andKind` / `orKind`) plus plain-identifier (`identKind`) kinds the
 * stranded-narrowing gate walks. `andLowerPrecedenceKinds` is the `RefShape` list
 * `collapsible-if` merges with — it decides the parenthesis pair when a caller asks
 * for the negation as an operand of the logical-and slot.
 */
typedef NegationSeams = {
	final notKind: Null<String>;
	final parenKind: Null<String>;
	final eqKind: Null<String>;
	final notEqKind: Null<String>;
	final atomicKinds: Array<String>;
	final andKind: Null<String>;
	final orKind: Null<String>;
	final identKind: String;
	final andLowerPrecedenceKinds: Array<String>;
};

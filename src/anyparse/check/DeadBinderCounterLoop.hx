package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.LoopScan.LoopSeams;
import anyparse.check.UsingScan.UsingHeader;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.NominalTypes;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.runtime.Span;

using StringTools;

/**
 * Flags a `for`-in loop that iterates a collection ONLY to count it — `var i = 0;` immediately followed by `for (x in coll) { … i++; }` where nothing reads the binder `x` — which a range `for` says directly: `for (i in 0...coll.length)`, with the declaration and the trailing increment gone. `Severity.Info`, paired with an autofix. DEFAULT OFF (`DefaultOff`): the input compiles and behaves correctly, so replacing it is a style choice — opt in with `"dead-binder-counter-loop": { "enabled": true }`.
 *
 * A collection with no `length` is counted through `Lambda.count`, and a `using Lambda;` is inserted when the file lacks one. That costs ONE extra traversal the original did not pay (`count()` walks, then the range loop walks again) — cheap for the containers below, and stated here rather than glossed.
 *
 * ## The shape it accepts
 *
 * Two ADJACENT statements in one STATEMENT LIST: a single-variable `var i = 0;` (NOT `final` — the counter is incremented) and a `for (x in coll)` over a bare identifier `coll`, whose braced body of at least two statements ENDS with exactly `i++;`. "Statement list" is `ControlFlowSupport.blockKinds()`, which deliberately EXCLUDES the conditional-compilation node: a `#if` region projects as one node holding every branch's statements as flat siblings, so pairing across it would splice through the `#else` and delete it. A pair written inside a `#if` is therefore not matched at all.
 *
 * ## Soundness gates (all required for a flag)
 *
 * - **The binder is dead.** No occurrence of `x` anywhere in the body — proved by a TEXT scan over the body span, not a node walk, because a missed mention here is a licence to DELETE the binder. A bare `'$x'` interpolation read and a `macro` reification subtree are both invisible to the tree and both would produce code that does not compile.
 * - **`i` is a pure counter.** The trailing `i++;` is its ONLY write, nothing after the loop reads it (a range `for` scopes `i` to the loop, whereas the `var` leaves the final count visible), nothing re-declares it in the body, and no closure in the enclosing scope captures it (a closure sees one shared binding where the range binder is per-iteration).
 * - **No `continue`.** In the `for`-in form a `continue` SKIPS the trailing `i++`, so `i` ends below the element count; a range `for` advances regardless. A `break` is fine — both forms stop at the same iteration.
 * - **`coll`'s length cannot move.** `0...coll.length` evaluates the bound ONCE where the `for`-in re-asks the iterator, so every mention of `coll` in the body must be a `length` read or an index read (see `LoopScan.usedOnlyAsStableCollection`, whose doc also states the BODY-LOCAL limit this rule inherits: an alias handed out earlier, or a call mutating `coll` through a field the callee owns, is outside what a per-file check can see).
 * - **`i` is an `Int`.** A declared non-`Int` counter cannot be a `...` range binder.
 *
 * ## The collection type must be provable
 *
 * Unlike its sibling `prefer-keyvalue-loop`, this check does NOT report an unresolved container: the replacement TEXT depends on the type (`length` vs `count()`), so a finding it cannot spell would be noise. `coll` must be a bare identifier whose binding is declared as one of the containers below, spelled either bare or `haxe.`-qualified (the match is on the SIMPLE nominal, so an unqualified project type of the same name is the residual — and it fails LOUDLY at compile time). Everything else — a path receiver, a call, an unannotated binding, a range — is silently skipped.
 *
 * - `length` (no `Lambda`): `Array`, `List`.
 * - `count()` (+ `using Lambda;`): `Map` and the concrete `haxe.ds` map types.
 *
 * That list is a WHITELIST on purpose. `Lambda.count` needs an `Iterable`, and "everything the language lets you write `for (x in …)` over" is strictly wider than that: an `Iterator` is accepted by `for` but is CONSUMED by a count, which would silently run the rewritten loop zero times, and `haxe.ds.HashMap` iterates but is an abstract that does not unify with `Iterable` at all. Naming the containers that provably work refuses that class by construction instead of by another exclusion.
 *
 * ## Grammar-agnostic
 *
 * Driven by `LoopScan.seamsOf` plus `RefShape.postIncrKind` / `continueStatementKind` / `exprStatementKind` / `mutableLocalDeclKinds` and `GrammarPlugin.controlFlowSupport`; any unset kind makes the check a no-op. The `length` / `count` member names and the container list are the language-specific tokens, spelled as constants.
 */
@:nullSafety(Strict)
final class DeadBinderCounterLoop implements Check implements DefaultOff {

	/** This check's stable id, spelled once. */
	private static inline final RULE_ID: String = 'dead-binder-counter-loop';

	/** The static-extension module supplying `count`. */
	private static inline final LAMBDA_MODULE: String = 'Lambda';

	/** The `Lambda` method counting an `Iterable`'s elements. */
	private static inline final COUNT_METHOD: String = 'count';

	/** The element-count member of a container that has one. */
	private static inline final LENGTH_MEMBER: String = 'length';

	/** The nominal a range binder must not provably differ from. */
	private static inline final INT_TYPE: String = 'Int';

	/** A single-binder `for` node has exactly [iterable, body] children. */
	private static inline final FOR_CHILD_COUNT: Int = 2;

	/** Minimum body statements: at least one real statement plus the trailing `i++`. */
	private static inline final MIN_BODY_STATEMENTS: Int = 2;

	/** The trailing `i++` is the counter's only write. */
	private static inline final COUNTER_WRITES: Int = 1;

	/** The package prefix a QUALIFIED container spelling must carry to be one the whitelist is about. */
	private static inline final STD_PACKAGE_PREFIX: String = 'haxe.';

	/**
	 * Container nominals whose element count is a plain `length` member — no `Lambda` needed.
	 * `Vector` is deliberately absent: the whitelist matches a SIMPLE nominal, and a geometry
	 * `Vector` whose `length` is a magnitude is a common enough spelling to make the name unsafe.
	 */
	private static final LENGTH_TYPES: Array<String> = ['Array', 'List'];

	/**
	 * Container nominals counted through `Lambda.count` — see the type doc for why this is a
	 * whitelist. `haxe.ds.HashMap` is deliberately ABSENT: a `for` accepts it, but it is an
	 * abstract that does not unify with `Iterable`, so `Lambda.count` does not apply to it.
	 */
	private static final COUNT_TYPES: Array<String> = ['Map', 'StringMap', 'IntMap', 'ObjectMap', 'EnumValueMap', 'BalancedTree'];

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a var i = 0 counter threaded through a for-in whose binder nothing reads, replaceable with a range for';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final s: Seams = seams;
		final typed: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		final violations: Array<Violation> = [];
		// Lazy: only the `count()` arm asks the index, so a project holding no map-counted loop
		// never builds the resolution scope.
		final index: () -> Null<SymbolIndex> = RefactorSupport.lazySymbolIndex(files, plugin);
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final types: Null<Map<Int, String>> = typed?.declaredTypeSources(entry.source);
			walk(tree, tree, entry.file, entry.source, types, s, index, violations);
		}
		return violations;
	}

	/**
	 * Rewrite each flagged pair into `for (i in 0...<count>) { … }` — one splice covering
	 * `[declaration, for end)` that carries the body's interior verbatim and drops both the
	 * declaration and the trailing increment — plus a `using Lambda;` insert when any rewrite
	 * needs `count()` and the file lacks one. A comment in either dropped region refuses that
	 * rewrite, leaving the finding report-only; so does a rival `using` that could also supply
	 * `count` (the inserted one would lose to it, silently retargeting the call).
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (seams == null || tree == null) return [];
		final s: Seams = seams;
		final typed: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		final types: Null<Map<Int, String>> = typed?.declaredTypeSources(source);
		final symbols: Null<SymbolIndex> = RefactorSupport.resolutionIndexOf(plugin) ?? index;
		final header: UsingHeader = UsingScan.headerOf(tree, source, plugin);
		final lambdaBlocked: Bool = UsingScan.conflictingUsing(
			UsingScan.usingModules(header), LAMBDA_MODULE, COUNT_METHOD, plugin, () -> symbols, []
		);
		final wanted: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) wanted.push('${span.from}:${span.to}');
		}
		final collected: Array<CountEdit> = [];
		fixWalk(tree, tree, source, types, s, wanted, lambdaBlocked, () -> symbols, collected);
		// The containment filter runs BEFORE the `using` decision, not after: a nested rewrite whose
		// edit an enclosing one swallows is not in the output, so neither is the `count()` that
		// needed `Lambda` — deciding first would leave an unused `using Lambda;` behind, which
		// widens static-extension resolution for the whole file.
		final edits: Array<{ span: Span, text: String }> = RefactorSupport.dropContainedEdits([for (c in collected) c.edit]);
		if (!keptNeedsLambda(collected, edits) || UsingScan.hasUsingModule(header, LAMBDA_MODULE)) return edits;
		final usingEdit: { span: Span, text: String } = UsingScan.usingInsertEdit(header, LAMBDA_MODULE);
		if (!RefactorSupport.editsOverlapAny([usingEdit], edits)) edits.push(usingEdit);
		return edits;
	}

	/** Whether any SURVIVING edit is the `count()` form — matched by span, since the containment filter rebuilds the list. */
	private static function keptNeedsLambda(collected: Array<CountEdit>, kept: Array<{ span: Span, text: String }>): Bool {
		for (c in collected) if (c.lambda) for (k in kept) if (k.span.from == c.edit.span.from && k.span.to == c.edit.span.to) return true;
		return false;
	}

	/** Bundle this check's kinds on top of the shared loop seams, or null when one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final core: Null<LoopSeams> = LoopScan.seamsOf(shape);
		if (core == null) return null;
		final postIncrKind: Null<String> = shape.postIncrKind;
		if (postIncrKind == null) return null;
		final continueKind: Null<String> = shape.continueStatementKind;
		if (continueKind == null) return null;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		if (exprStmtKind == null) return null;
		// The pair scan must run over STATEMENT LISTS only. A `#if` region projects as ONE node
		// whose children are every branch's statements as FLAT siblings, so scanning it would pair
		// a declaration in one branch with a loop in another and splice straight through the
		// `#else`, deleting it — and would take the region, not the block, as the scope its
		// read-after gate scans to. `blockKinds()` is the codebase's standing answer to exactly
		// that, and it excludes the conditional node.
		final flow: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (flow == null) return null;
		final mutableKinds: Array<String> = shape.mutableLocalDeclKinds ?? [];
		return mutableKinds.length == 0 ? null : {
			core: core,
			postIncrKind: postIncrKind,
			continueKind: continueKind,
			exprStmtKind: exprStmtKind,
			blockKinds: flow.blockKinds(),
			mutableKinds: mutableKinds
		};
	}

	/**
	 * Descend `node`, testing each adjacent child pair `(decl, for)` and recursing; `node` doubles
	 * as the enclosing scope for the read-after and closure-capture gates. A reification subtree is
	 * skipped wholesale.
	 */
	private static function walk(
		node: QueryNode, root: QueryNode, file: String, source: String, types: Null<Map<Int, String>>, s: Seams,
		index: () -> Null<SymbolIndex>, out: Array<Violation>
	): Void {
		if (s.core.opaqueKinds.contains(node.kind)) return;
		final kids: Array<QueryNode> = node.children;
		if (s.blockKinds.contains(node.kind)) for (i in 0...kids.length - 1) {
			final m: Null<Match> = analyze(kids[i], kids[i + 1], node, root, source, types, s, index);
			if (m != null) out.push({
				file: file,
				span: m.declSpan,
				rule: RULE_ID,
				severity: Severity.Info,
				message: 'this loop discards its binder and counts by hand — it can be for (${m.counter} in 0...${m.bound})'
			});
		}
		for (c in kids) walk(c, root, file, source, types, s, index, out);
	}

	/** Mirror of `walk` for the fix path: emit the range-loop rewrite for each wanted, rewritable pair. */
	private static function fixWalk(
		node: QueryNode, root: QueryNode, source: String, types: Null<Map<Int, String>>, s: Seams, wanted: Array<String>,
		lambdaBlocked: Bool, index: () -> Null<SymbolIndex>, out: Array<CountEdit>
	): Void {
		if (s.core.opaqueKinds.contains(node.kind)) return;
		final kids: Array<QueryNode> = node.children;
		if (s.blockKinds.contains(node.kind)) for (i in 0...kids.length - 1) {
			final m: Null<Match> = analyze(kids[i], kids[i + 1], node, root, source, types, s, index);
			if (m == null || !wanted.contains('${m.declSpan.from}:${m.declSpan.to}')) continue;
			if (m.needsLambda && lambdaBlocked) continue;
			final e: Null<{ span: Span, text: String }> = buildEdit(m, source);
			if (e == null) continue;
			// Re-bound because strict null-safety narrowing does not reach INTO a struct literal.
			final edit: { span: Span, text: String } = e;
			out.push({ edit: edit, lambda: m.needsLambda });
		}
		for (c in kids) fixWalk(c, root, source, types, s, wanted, lambdaBlocked, index, out);
	}

	/**
	 * The matched `(decl, for)` pair inside `scope` — the spans the rewrite splices, the counter
	 * name and the bound expression that replaces the iteration — or null when any gate fails.
	 * Shared by `walk` (report) and `fixWalk` (rewrite) so both see one decision.
	 */
	private static function analyze(
		decl: QueryNode, forNode: QueryNode, scope: QueryNode, root: QueryNode, source: String, types: Null<Map<Int, String>>, s: Seams,
		index: () -> Null<SymbolIndex>
	): Null<Match> {
		final core: LoopSeams = s.core;
		final shape = matchShape(decl, forNode, source, s);
		if (shape == null) return null;
		final sh = shape;
		final declSpan: Null<Span> = decl.span;
		final forSpan: Null<Span> = forNode.span;
		final bodySpan: Null<Span> = sh.body.span;
		final incrSpan: Null<Span> = sh.incr.span;
		final scopeSpan: Null<Span> = scope.span;
		if (declSpan == null || forSpan == null || bodySpan == null || incrSpan == null || scopeSpan == null) return null;
		if (declaredNonInt(declSpan.from, types)) return null;
		// The binder-is-dead proof is a TEXT scan, not a node walk. A bare `'$x'` interpolation read
		// and a `macro` reification subtree both hide the mention from the tree, and HERE a missed
		// mention is a licence to DELETE the binder — the unsafe direction of the imprecision.
		if (RefactorSupport.referencedInRange(source, sh.binder, bodySpan.from, bodySpan.to, [])) return null;
		if (!bodyAdmitsRewrite(sh.body, sh.counter, sh.collection, s)) return null;
		if (RefactorSupport.referencedInRange(source, sh.counter, forSpan.to, scopeSpan.to, [])) return null;
		if (LoopScan.capturedByClosure(scope, source, sh.counter, core)) return null;
		final bound: Null<Bound> = boundOf(sh.collection, LoopScan.identTypeSource(sh.iterable, root, types, core), index);
		return bound == null ? null : {
			declSpan: declSpan,
			forSpan: forSpan,
			bodySpan: bodySpan,
			incrSpan: incrSpan,
			counter: sh.counter,
			bound: bound.expr,
			needsLambda: bound.lambda
		};
	}

	/**
	 * The pair's SHAPE — a single-variable `var i = 0;` next to a single-binder `for` over a bare
	 * identifier, whose braced body of at least two statements ends in `i++;` — or null when it is
	 * anything else. Split out of `analyze` so each half stays readable on its own.
	 */
	private static function matchShape(decl: QueryNode, forNode: QueryNode, source: String, s: Seams): Null<{
		counter: String,
		binder: String,
		collection: String,
		iterable: QueryNode,
		body: QueryNode,
		incr: QueryNode
	}> {
		final core: LoopSeams = s.core;
		final counter: Null<String> = LoopScan.singleLocalDeclName(decl, s.mutableKinds, core);
		if (counter == null || !LoopScan.isZeroLiteral(decl.children[0], source, core)) return null;
		if (forNode.kind != core.forStmtKind || forNode.children.length != FOR_CHILD_COUNT) return null;
		final binder: Null<String> = forNode.name;
		if (binder == null || binder == counter) return null;
		final iterable: QueryNode = forNode.children[0];
		final collection: Null<String> = LoopScan.bareIdentName(iterable, core);
		if (collection == null || collection == counter) return null;
		final body: QueryNode = forNode.children[1];
		if (body.kind != core.blockStmtKind || body.children.length < MIN_BODY_STATEMENTS) return null;
		final incr: QueryNode = body.children[body.children.length - 1];
		return !isPostIncrementOf(incr, counter, s) ? null : {
			counter: counter,
			binder: binder,
			collection: collection,
			iterable: iterable,
			body: body,
			incr: incr
		};
	}

	/**
	 * Whether the body tolerates the rewrite: the trailing increment is the counter's only write,
	 * nothing mentions the dead binder, no `continue` skips the increment, nothing re-declares the
	 * counter, and the collection is never written nor used anywhere its length could move.
	 */
	private static function bodyAdmitsRewrite(body: QueryNode, counter: String, collection: String, s: Seams): Bool {
		final core: LoopSeams = s.core;
		if (LoopScan.countWrites(body, counter, core) != COUNTER_WRITES) return false;
		if (LoopScan.containsKind(body, s.continueKind, core)) return false;
		if (LoopScan.declares(body, counter, core)) return false;
		return LoopScan.usedOnlyAsStableCollection(body, collection, LENGTH_MEMBER, core);
	}

	/** Whether `stmt` is exactly `<counter>++;` — an expression statement wrapping a post-increment of the counter. */
	private static function isPostIncrementOf(stmt: QueryNode, counter: String, s: Seams): Bool {
		if (stmt.kind != s.exprStmtKind || stmt.children.length != 1) return false;
		final incr: QueryNode = stmt.children[0];
		return incr.kind == s.postIncrKind && incr.children.length >= 1 && LoopScan.bareIdentName(incr.children[0], s.core) == counter;
	}

	/**
	 * The bound expression counting `collection`, or null when its declared container is not one
	 * this rewrite can spell — or when the `count()` form would not reach `Lambda`.
	 *
	 * The whitelist matches a SIMPLE nominal, which is what makes a project type named after a std
	 * container the residual this check's type doc names. For the `length` arm that residual is
	 * harmless (a `length` member is a real member either way); for the `count()` arm it is not,
	 * because the emitted call goes through the `using Lambda;` the fix inserts and Haxe binds a
	 * real MEMBER first. `SymbolIndex.memberShadowsExtension` — the one question shared with
	 * `prefer-exists` / `prefer-foreach` / `prefer-find` / `prefer-static-extension` — turns that
	 * into a silent skip instead of a rewrite whose `count()` lands somewhere else.
	 */
	private static function boundOf(collection: String, typeSource: Null<String>, index: () -> Null<SymbolIndex>): Null<Bound> {
		if (typeSource == null || !stdlibSpelling(typeSource)) return null;
		final nominal: Null<String> = NominalTypes.outerNominalOf(typeSource);
		return if (nominal == null)
			null
		else if (LENGTH_TYPES.contains(nominal))
			{ expr: '${collection}.$LENGTH_MEMBER', lambda: false }
		else if (COUNT_TYPES.contains(nominal) && !countShadowed(nominal, index))
			{ expr: '${collection}.$COUNT_METHOD()', lambda: true }
		else
			null;
	}

	/** Whether `nominal` provably declares a `count` member of its own, which the inserted `using Lambda;` would never beat. */
	private static function countShadowed(nominal: String, index: () -> Null<SymbolIndex>): Bool {
		final symbols: Null<SymbolIndex> = index();
		return symbols != null && symbols.memberShadowsExtension(nominal, COUNT_METHOD);
	}

	/**
	 * Whether the written type is spelled as a container the whitelist can be ABOUT — a bare simple
	 * name, or a `haxe.`-qualified path. The whitelist matches the SIMPLE nominal, so without this a
	 * project-local `mygame.Map` (no `count`) would be admitted by its last segment alone. A bare
	 * name an `import` rebinds to a project type is the residual, and it fails LOUDLY at compile
	 * time rather than silently at run time.
	 */
	private static function stdlibSpelling(typeSource: String): Bool {
		final lt: Int = typeSource.indexOf('<');
		final head: String = StringTools.trim(lt < 0 ? typeSource : typeSource.substring(0, lt));
		return head.lastIndexOf('.') < 0 || head.startsWith(STD_PACKAGE_PREFIX);
	}

	/** Whether the declaration binding at `from` carries an explicit non-`Int` annotation. */
	private static function declaredNonInt(from: Int, types: Null<Map<Int, String>>): Bool {
		if (types == null) return false;
		final source: Null<String> = types[from];
		return source != null && NominalTypes.outerNominalOf(source) != INT_TYPE;
	}

	/**
	 * The single `{span, text}` replacing `[declaration, for end)` with the range loop — or null
	 * when a comment sits in a dropped region: the declaration plus the gap and the `for` header,
	 * or the stretch between the increment and the body's `}`. The interior `[body {, increment)`
	 * is carried verbatim, so comments there survive.
	 */
	private static function buildEdit(m: Match, source: String): Null<{ span: Span, text: String }> {
		if (CheckScan.hasCommentMarker(source, m.declSpan.from, m.bodySpan.from)) return null;
		if (CheckScan.hasCommentMarker(source, m.incrSpan.to, m.bodySpan.to - 1)) return null;
		final interior: String = source.substring(m.bodySpan.from + 1, m.incrSpan.from);
		return { span: new Span(m.declSpan.from, m.forSpan.to), text: 'for (${m.counter} in 0...${m.bound}) {$interior}' };
	}

}

/** The `RefShape` kinds `DeadBinderCounterLoop` reads on top of the shared `LoopScan` core. */
private typedef Seams = {
	var core: LoopSeams;
	var postIncrKind: String;
	var continueKind: String;
	var exprStmtKind: String;
	var blockKinds: Array<String>;
	var mutableKinds: Array<String>;
}

/** The counting expression a matched container yields, plus whether it needs `using Lambda;` in scope. */
private typedef Bound = {
	var expr: String;
	var lambda: Bool;
}

/** One collected rewrite plus whether its bound is the `count()` form — the pair `fix` re-reads after the containment filter. */
private typedef CountEdit = {
	var edit: { span: Span, text: String };
	var lambda: Bool;
}

/** One matched pair: the spans the rewrite splices, the counter it re-binds, and the bound that replaces the iteration. */
private typedef Match = {
	var declSpan: Span;
	var forSpan: Span;
	var bodySpan: Span;
	var incrSpan: Span;
	var counter: String;
	var bound: String;
	var needsLambda: Bool;
}

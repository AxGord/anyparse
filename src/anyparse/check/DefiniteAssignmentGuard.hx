package anyparse.check;

import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

using Lambda;

/**
 * The compiler-free half of `lint --fix`'s revert net: whether an edit set would leave a local
 * READ before the language considers it assigned.
 *
 * ## The hole it closes
 *
 * A SAFE check's fix is applied unverified. `Cli.reconcileSafePass` — the green-then-red
 * rollback — opens with `if (pre == null || oracleHxml == null) return {reverted: false}`, so it
 * exists ONLY for a run that both configures `apqlint.json` `compilerOracle` and measured the
 * tree green before the writes. Measured on the T445 fixture with S54's closure guard removed,
 * one deleting `dead-store` fix run three ways: `--no-oracle` wrote the corrupting edit, a
 * config with no `compilerOracle` wrote it, and only the oracle arm reverted. Two of the three
 * arms are the project's own documented edit loop and every project that never configured a
 * compiler.
 *
 * ## What the compiler actually refuses
 *
 * The rule this guard mirrors was MEASURED on Haxe 4.3.7, not assumed, and the first thing the
 * measurement did was refute the obvious model. A write inside a closure is NOT excluded from
 * definite assignment:
 *
 *   var found; map(t, run -> { found = true; return run; }); return found;      // COMPILES
 *   var found; map(t, run -> { if (c) found = true; return run; }); return found;  // ERROR
 *   var found; if (c) found = true; return found;                              // ERROR
 *   var found; if (c) found = true else found = false; return found;           // COMPILES
 *   var found; if (c) found = true else return false; return found;            // COMPILES
 *   var found; while (c) { found = true; break; } return found;                // ERROR
 *   var found; for (i in 0...1) found = true; return found;                     // COMPILES
 *   var found; map(t, run -> { if (c) found = true; return found; });           // WARNING only
 *
 * So the compiler walks a lambda body as ordinary code at its position, and the construct that
 * withholds an assignment is the `if` — not the closure. A guard built on the closure asymmetry
 * refuses correct fixes: measured, it declined a real `dead-code` edit whose output compiles.
 *
 * ## What it answers
 *
 * A candidate is a local whose declaration carries no initializer. A forward must-assign walk in
 * document order marks a candidate assigned at its declaration initializer or at any write whose
 * target is the bare name; an `if` is analysed — its arms in copies, merged back by what BOTH
 * assign, with an arm that cannot fall through contributing no path — and EVERY other construct
 * is walked as a plain sequence. Reading a candidate that is not assigned, OUTSIDE every nested
 * function value, is a finding.
 *
 * Walking loops, switches, `try` and ternaries as sequences is the optimistic reading: it can
 * only add to the assigned set, so it can only lose a finding, never invent one. That direction
 * is deliberate — a gate that refuses a correct fix costs a fix, and the compiler is still
 * behind this guard wherever a project configures an oracle.
 *
 * The answer is DIFFERENTIAL: the same question is asked of the source and of the spliced
 * result, and only a name the result flags and the source did not is a refusal. A file that
 * already reads that way is not the fix's doing.
 *
 * Grammar-agnostic: every kind vocabulary comes from `RefShape` and `NullFlow`'s construct sets,
 * and the nested-function set from `RefactorSupport.nestedFunctionKinds`, which S56 made the one
 * authority. A grammar declaring none of them makes the guard inert.
 *
 * ## What it does NOT reach, by construction
 *
 *  - **The memo form.** An edit that deletes a write to a local whose declaration DOES carry an
 *    initializer leaves a tree that typechecks, emits identical bytes and trips no rule — T94's
 *    shape, where `lint --fix` deleted both writes to two closure-captured memo locals and left
 *    them `final = null`. The only observable was wall clock, which is why that defect ran two
 *    weeks. Definite assignment holds there, so this guard is silent BY DESIGN.
 *  - **Everything the compiler refuses that this walk reads optimistically.** The loop row above
 *    is the measured example: `while (c) { x = 1; break; }` is an error and this guard is quiet.
 *    Pinned as a deliberate miss rather than left to be discovered.
 *  - **A break two checks make BETWEEN them.** The guard is asked per CHECK, so an edit set that
 *    is sound alone and unsound beside another check's is not seen. `BodySlotGuard` answers the
 *    same way for the same reason; there `RefactorSupport.canonicalize` is the whole-file
 *    backstop, here it is the oracle arm when a project has one.
 */
@:nullSafety(Strict)
final class DefiniteAssignmentGuard {

	/**
	 * The refusal message for the first local `edits` would leave read before it is assigned, or
	 * null when they leave none — the answer `Cli.collectFileLintEdits` reads beside
	 * `BodySlotGuard.emptiedSlot`.
	 *
	 * Two parses: the SOURCE one is the caller's own, served from the run-scoped
	 * `CachingGrammarPlugin` cache, and the RESULT one is the real cost. There is no pre-filter in
	 * front of it, and that is a measured decision rather than an oversight — a version that walked
	 * the source tree first and returned early when no edit reached a declaration or a write was
	 * byte-identical in outcome and NOT faster: anyparse `src` + `test` 115.0 s with it against
	 * 114.1 s without, Pony 869 files 30.0 s either way, both inside the 0.4 s spread of the
	 * identical binary. The walk it saved cost about what the parse it skipped did.
	 *
	 * Unparseable input on either side answers null: the caller's own parse is about to report it in
	 * its own words.
	 */
	public static function unassignedRead(source: String, edits: Array<{ span: Span, text: String }>, plugin: GrammarPlugin): Null<String> {
		if (edits.length == 0) return null;
		final shape: RefShape = plugin.refShape();
		final vocab: Null<Vocabulary> = vocabulary(shape);
		if (vocab == null) return null;
		final before: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (before == null) return null;
		final spliced: String = RefactorSupport.applyEdits(source, edits);
		final after: Null<QueryNode> = CheckScan.parseOrNull(plugin, spliced);
		if (after == null) return null;
		final stood: Array<String> = [for (had in findings(before, shape, vocab)) had.name];
		for (hit in findings(after, shape, vocab)) if (!stood.contains(hit.name)) return message(hit, spliced);
		return null;
	}

	/**
	 * Every local `root` reads before anything assigns it, one entry per name per function unit —
	 * the whole judgement, and the one both sides of the differential are asked.
	 */
	public static function findings(root: QueryNode, shape: RefShape, vocab: Vocabulary): Array<UnassignedRead> {
		final out: Array<UnassignedRead> = [];
		NullFlow.forEachFunctionUnit(root, shape, (body, _) -> unitFindings(body, vocab, out));
		return out;
	}

	/**
	 * The kind vocabulary this guard needs, or null when the grammar declares too little of it
	 * to answer — read once per call so no walker re-derives it, and so a grammar that names
	 * no local declarations or no writes makes the guard inert rather than silently vacuous.
	 */
	public static function vocabulary(shape: RefShape): Null<Vocabulary> {
		final identKind: Null<String> = shape.identKind;
		final declKinds: Array<String> = shape.localDeclKinds ?? [];
		final writeKinds: Array<String> = shape.writeParentKinds ?? [];
		return identKind == null || declKinds.length == 0 || writeKinds.length == 0 ? null : {
			identKind: identKind,
			interpIdentKind: shape.stringInterpIdentKind,
			declKinds: declKinds,
			writeKinds: writeKinds,
			continuationKinds: shape.localDeclContinuationKinds ?? [],
			typeChildKinds: shape.declTypeChildKinds ?? [],
			ifKinds: NullFlow.IF_KINDS,
			nestedFnKinds: RefactorSupport.nestedFunctionKinds(shape),
			metaKinds: NullFlow.META_KINDS,
			exitKinds: shape.controlExitKinds ?? []
		};
	}

	/** Record `name` as definitely assigned, deduplicated. */
	private static inline function mark(assigned: Array<String>, name: String): Void {
		if (!assigned.contains(name)) assigned.push(name);
	}

	/** Append every finding of ONE function unit's body to `out`. */
	private static function unitFindings(body: QueryNode, vocab: Vocabulary, out: Array<UnassignedRead>): Void {
		final declared: Array<String> = [];
		collectDeclared(body, vocab, declared);
		final candidates: Array<String> = [
			for (name in declared) if (declared.indexOf(name) == declared.lastIndexOf(name)) name
		];
		if (candidates.length == 0) return;
		visit(body, {
			vocab: vocab,
			candidates: candidates,
			inScope: [],
			out: out
		}, [], false);
	}

	/**
	 * Every local the unit declares WITHOUT an initializer, duplicates kept — a name that turns up
	 * twice is dropped from the candidate set, because a name-keyed walk cannot tell two bindings
	 * apart and the direction that costs a correct fix is the refusing one. A shadow pair where one
	 * of the two DOES carry an initializer is not seen as a pair, and does not need to be: the
	 * initialised one marks the name assigned as the walk passes it, so the shadow can only lose a
	 * finding.
	 *
	 * Nested function values are walked THROUGH, not skipped, for the reason the whole analysis
	 * turns on: measured on Haxe 4.3.7, the compiler treats a lambda body as ordinary code at its
	 * position, so a local declared there is in the same name space as far as this walk is concerned.
	 */
	private static function collectDeclared(node: QueryNode, vocab: Vocabulary, out: Array<String>): Void {
		if (vocab.metaKinds.contains(node.kind)) return;
		final name: Null<String> = node.name;
		if (vocab.declKinds.contains(node.kind) && name != null && !hasInitializer(node, vocab)) out.push(name);
		for (child in node.children) collectDeclared(child, vocab, out);
	}

	/**
	 * The forward must-assign walk over one unit, in document order: `assigned` is the set of
	 * candidate names definitely written on every path to here, and a read of a candidate in
	 * scope that is not in it is a finding.
	 *
	 * ONE construct is analysed rather than walked — the `if`, because it is the only one whose
	 * omission would make the whole guard vacuous (the T445 shape is a write under an unguarded
	 * `if`). Its arms are walked in copies and only what BOTH assign is merged back; an arm that
	 * exits contributes no path, so its sibling's writes carry. Every other construct — loops,
	 * switches, `try`, ternaries, short-circuits — is walked as a plain sequence, which is the
	 * OPTIMISTIC reading: it can only add to `assigned`, so it can only lose a finding, never
	 * invent one. That direction is deliberate. A gate that refuses a correct fix costs a fix,
	 * and the compiler is behind this guard whenever a project configures an oracle.
	 */
	private static function visit(node: QueryNode, ctx: WalkCtx, assigned: Array<String>, nested: Bool): Void {
		final vocab: Vocabulary = ctx.vocab;
		if (vocab.metaKinds.contains(node.kind)) return;
		final inner: Bool = nested || vocab.nestedFnKinds.contains(node.kind);
		if (vocab.ifKinds.contains(node.kind) && node.children.length > 1) {
			visitIf(node, ctx, assigned, inner);
			return;
		}
		final name: Null<String> = node.name;
		if (vocab.declKinds.contains(node.kind) && name != null) {
			visitDecl(node, name, ctx, assigned, inner);
			return;
		}
		if (vocab.writeKinds.contains(node.kind) && node.children.length > 0) {
			visitWrite(node, ctx, assigned, inner);
			return;
		}
		if (name != null && (node.kind == vocab.identKind || node.kind == vocab.interpIdentKind)) {
			// Only a read OUTSIDE every nested function value is an ERROR for the compiler.
			// Measured on Haxe 4.3.7: the same guarded-write shape read from INSIDE the closure
			// is `Warning: (WVarInit) Local variable found might be used before being
			// initialized` and compiles, so refusing it would decline a fix the oracle arm keeps.
			if (!nested && ctx.inScope.contains(name) && ctx.candidates.contains(name) && !assigned.contains(name))
				report(ctx, name, node.span);
			return;
		}
		for (child in node.children) visit(child, ctx, assigned, inner);
	}

	/**
	 * A declaration: its own initializer is evaluated, then the name enters scope and — when it
	 * HAS one — becomes assigned, and only then do the continuation declarators run, so
	 * `var a = 1, b = a;` does not read `a` before its own initializer landed.
	 */
	private static function visitDecl(node: QueryNode, name: String, ctx: WalkCtx, assigned: Array<String>, nested: Bool): Void {
		final vocab: Vocabulary = ctx.vocab;
		for (child in node.children) if (!vocab.continuationKinds.contains(child.kind)) visit(child, ctx, assigned, nested);
		if (!ctx.inScope.contains(name)) ctx.inScope.push(name);
		if (hasInitializer(node, vocab)) mark(assigned, name);
		for (child in node.children) if (vocab.continuationKinds.contains(child.kind)) visit(child, ctx, assigned, nested);
	}

	/**
	 * A write: the right-hand side first, then the target is assigned. A target that is not a
	 * bare identifier — `found.flag = true` — writes a FIELD, so it is walked as an ordinary
	 * read of the receiver and assigns nothing.
	 */
	private static function visitWrite(node: QueryNode, ctx: WalkCtx, assigned: Array<String>, nested: Bool): Void {
		final target: QueryNode = node.children[0];
		// Captured as a nullable NAME rather than a Bool: the null check is what makes the write
		// below reachable under strict null safety, and a separate `bare` flag would leave a
		// second, redundant-looking one behind.
		final bare: Null<String> = target.kind == ctx.vocab.identKind ? target.name : null;
		if (bare == null) visit(target, ctx, assigned, nested);
		for (i in 1...node.children.length) visit(node.children[i], ctx, assigned, nested);
		if (bare != null) mark(assigned, bare);
	}

	/** The `if` arms in isolated states, merged back by what BOTH of them assign. */
	private static function visitIf(node: QueryNode, ctx: WalkCtx, assigned: Array<String>, nested: Bool): Void {
		visit(node.children[0], ctx, assigned, nested);
		final thenArm: QueryNode = node.children[1];
		final thenState: Array<String> = assigned.copy();
		visit(thenArm, ctx, thenState, nested);
		if (node.children.length < 3) return;
		final elseArm: QueryNode = node.children[2];
		final elseState: Array<String> = assigned.copy();
		visit(elseArm, ctx, elseState, nested);
		// An arm that cannot fall through contributes no path, so the OTHER arm's writes are
		// what reaches here — the shape `if (c) x = 1 else return false;` depends on, and a
		// plain intersection would refuse it.
		final thenExits: Bool = exits(thenArm, ctx.vocab);
		final elseExits: Bool = exits(elseArm, ctx.vocab);
		for (n in thenState) if (thenExits || elseExits ? true : elseState.contains(n)) mark(assigned, n);
		for (n in elseState) if (thenExits || elseExits) mark(assigned, n);
	}

	/**
	 * Whether an arm cannot fall through — its last statement, transitively, is a control exit.
	 * Reading only the LAST child is deliberately optimistic (an `if` whose then-arm returns
	 * answers true here though it may not fire): the merge then keeps MORE names assigned, which
	 * loses findings rather than inventing them.
	 */
	private static function exits(node: QueryNode, vocab: Vocabulary): Bool {
		return vocab.exitKinds.contains(node.kind) || node.children.length > 0 && exits(node.children[node.children.length - 1], vocab);
	}

	/** Record one finding, at most one per name per unit. */
	private static function report(ctx: WalkCtx, name: String, span: Null<Span>): Void {
		for (had in ctx.out) if (had.name == name) return;
		ctx.out.push({
			name: name,
			span: span
		});
	}

	/**
	 * Whether a local declaration carries an initializer.
	 *
	 * NOT `NullFlow.declInit`, and the divergence is one shape wide but load-bearing. That helper
	 * reads the LAST child and calls it the initializer unless its kind is in `declTypeChildKinds`,
	 * which does not name the CONTINUATION declarator: for `var a, b = 1;` it hands back the
	 * `VarMore` node and reports that `a` has an initializer. `a` has none, and the compiler says so
	 * (`Local variable a used without being initialized`). This asks for any child that is neither a
	 * type child nor a continuation, and takes the SPAN as the proof that it is real source.
	 *
	 * Measured, not assumed: swapping this for `declInit` leaves every other fixture in
	 * `DefiniteAssignmentGuardTest` green — the annotated form `var c: Bool;` the two were once
	 * believed to disagree on is answered identically by both — and flips exactly the
	 * multi-declarator one.
	 */
	private static function hasInitializer(node: QueryNode, vocab: Vocabulary): Bool {
		return node.children.exists(
			child -> child.span != null && !vocab.typeChildKinds.contains(child.kind) && !vocab.continuationKinds.contains(child.kind)
		);
	}

	/** The refusal sentence for one finding, positioned in the source it was found in. */
	private static function message(hit: UnassignedRead, spliced: String): String {
		final at: Null<Span> = hit.span;
		final where: String = at == null ? '' : ' at ${at.lineCol(spliced).line}:${at.lineCol(spliced).col}';
		return 'this would leave the local `${hit.name}`$where read before anything assigns it — no write reaches it on every path, and a '
			+ 'write under an `if` with no `else` is not one; keep the initializer, or assign the local before the read';
	}

}

/**
 * One local a fix would leave read with nothing to assign it: the name, and the READ's span
 * in whichever source the finding was taken from.
 */
typedef UnassignedRead = {
	final name: String;
	final span: Null<Span>;
}

/**
 * The kind vocabulary `DefiniteAssignmentGuard` reads out of `RefShape` once per call, so the
 * walkers take names rather than re-deriving a set per node.
 */
typedef Vocabulary = {
	final identKind: String;
	final interpIdentKind: Null<String>;
	final declKinds: Array<String>;
	final writeKinds: Array<String>;
	final continuationKinds: Array<String>;
	final typeChildKinds: Array<String>;
	final ifKinds: Array<String>;
	final nestedFnKinds: Array<String>;
	final metaKinds: Array<String>;
	final exitKinds: Array<String>;
}

/**
 * The per-unit walk state: the vocabulary, the names this unit declares without an
 * initializer exactly once, the ones whose declaration the walk has passed, and the findings.
 * Threaded as one record so the assigned-set stays the only thing an arm copies.
 */
typedef WalkCtx = {
	final vocab: Vocabulary;
	final candidates: Array<String>;
	final inScope: Array<String>;
	final out: Array<UnassignedRead>;
}

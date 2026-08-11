package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.FieldWriteIndex;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags an INSTANCE field (`var` or `final`) that has NO declaration initializer but
 * whose write is one unconditional constructor assignment `x = expr` / `this.x = expr`
 * whose right-hand side is context-independent
 * (references no constructor parameters, no `this`, no other instance members, no
 * constructor locals — only literals, static / global references, and constructions
 * such as `new Shape()`). `Severity.Info`, with an autofix that MOVES `= expr` onto
 * the field declaration and removes the constructor write — e.g.
 * `private var _a:Array<Int>;` + constructor `_a = new Array<Int>();` becomes
 * `private var _a:Array<Int> = new Array<Int>();`.
 *
 * ## Soundness — why the move is order-safe
 *
 * A declaration initializer runs BEFORE the constructor body, so moving an init
 * earlier is safe only when the moved expression does not depend on anything the
 * constructor establishes first. The context-free right-hand-side gate guarantees
 * exactly that: every identifier read resolves to a global / type / static member (a
 * value available at declaration-init time), never to a constructor parameter or
 * local (which do not exist yet), another instance member (a field that may be
 * uninitialized), or `this`. Combined with the exactly-one-write proof
 * (`FieldWriteIndex.writeCount == 1` and no unresolved write to the field NAME), the
 * moved statement is the field's SOLE assignment, so the move preserves behaviour.
 *
 * ORDER is only half of what the prologue changes; REACHABILITY is the other half. A
 * constructor body need not reach its own statements — an early `return` behind a
 * feature flag, a `throw`, a loop that never ends — while a declaration initializer
 * ALWAYS runs. So a candidate additionally demands
 * `RefactorSupport.ctorPrefixUnconditional`: every top-level statement before its init
 * provably COMPLETES NORMALLY (an expression statement, a local declaration, an `if` /
 * `switch` / `try`, a local `function` declaration, a `#if` region; `super(…)` is an
 * expression statement — a LOOP is the one shape not admitted, since it need not
 * terminate) and no control exit AND no loop starts before it anywhere in the body
 * subtree. The live regression that bought this gate hoisted an asset load out from
 * behind `if (!USE_CACHE) return;`, making it unconditional; the moved code still
 * type-checked and still parsed, so nothing downstream could catch it. The `if` itself
 * is admitted — it is the `return` inside it that the subtree scan refuses. The gate
 * sits on the CANDIDATE, not on either acceptance path below, so neither path can miss
 * it.
 *
 * The prologue also runs ahead of the BASE constructor, which is a third boundary no init
 * may cross. Haxe emits declaration initializers before the constructor BODY, and an
 * explicit `super()` call lives INSIDE that body: a subclass whose constructor reads
 * `super(); asset = Loader.get('pack');`, over a base constructor that sets the
 * `Loader.ready` flag `get` consults, printed `real:pack` as written and `TOO-EARLY:pack`
 * once the init moved onto the declaration (4.3.7, `--interp`). `ctorCallsSuper` therefore
 * refuses a candidate whose constructor calls up ANYWHERE, and it gates the CANDIDATE for
 * the same reason `ctorPrefixUnconditional` does, so both acceptance paths inherit it. With
 * `superReferenceText` or `callKind` unset the call cannot be recognised at all, and the
 * gate falls back to `hasSupertype`, which refuses every subclass — coarser, still
 * closed. That fallback rests on ONE MORE optional seam, and there the gate does degrade
 * OPEN: `hasSupertype` reads `supertypeClauseKinds ?? []` and answers false on an empty
 * list, so a plugin declaring NONE of the three seams gets no gate at all rather than a
 * coarse one. Deliberately not closed in code by making an undeclared
 * `supertypeClauseKinds` refuse every container — that would kill the rule for any language
 * with no inheritance concept. Nothing is exposed today (`HaxeQueryPlugin` sets all three
 * and is the only `RefShape` producer); this paragraph is the contract a future plugin
 * author reads.
 *
 * That rule is deliberately COARSER than the sound one. Only an init sitting AFTER the
 * `super(…)` crosses the boundary — `new() { x = 1; super(); }` is fine, and 4.3.7 prints
 * the right value for it — but the finer test is not one lexical comparison: the `super(…)`
 * call need not be a top-level statement (it can sit inside an `if` / `switch` / `#if`
 * region, and appear more than once on different branches), so "the init precedes THE super
 * call" often has no answer at all, and every branch where the proof is unavailable
 * reintroduces exactly this regression, which still type-checks, still parses, and which
 * nothing downstream catches. What the finer rule would buy is a subclass constructor
 * assigning a CONTEXT-FREE constant to a field BEFORE calling up, and that shape is
 * vanishingly rare. Measured: of the 15 sites the gate removes from the 676-file `pony`
 * tree (34 -> 19), FOURTEEN put the init after the `super(…)` — real hazards, correctly
 * refused — and ONE (`pony/net/cs/SocketClient`, whose `super(host, port, …)` is the
 * constructor's LAST statement) is an over-refusal the finer rule would have kept. On the
 * other two measured trees there is nothing to weigh either way: `TM-Haxe4/src` (798
 * files) and this repo (1254 files) report the rule dormant BEFORE and AFTER, so they
 * neither confirm the figure above nor add to it. At `Severity.Info` — a cosmetic
 * move — one lost cleanup per 676 files does not buy the branch analysis.
 *
 * A field whose cross-file write count DIFFERS FROM ONE (a `dispose()` null-out, say)
 * can still move, on the ACCEPTED-CANDIDATE CHAIN: every top-level constructor
 * statement before its init must itself be the init of another accepted candidate of
 * the same constructor. Two pillars carry that, and NEITHER is "the prefix runs no
 * foreign code" — foreign code MAY run in an accepted prefix (`new T()` and static
 * calls are context-free), which is exactly why the second pillar is needed:
 *
 * - INSTANCE-UNREACHABILITY. No accepted-prefix right-hand side can leak `this`
 *   (`contextFreeRhs` refuses `this` and every in-class non-static resolution), and
 *   no other statement shape is allowed in the prefix — no bare call, no
 *   `super(...)`, no local declaration, no branch or loop. So the second writer of
 *   the field, wherever it lives, cannot be reached in the window the move opens;
 *   `super(...)` is barred precisely because an overridden method invoked from the
 *   SUPERCLASS constructor could write the field.
 * - ORDER-INDEPENDENCE. Moving an init changes WHERE its right-hand side runs
 *   relative to every other init in the constructor prologue: they all land there in
 *   whatever sequence the compiler emits them, which is not the sequence the moved
 *   ones had as statements. The gate is therefore per-right-hand-side and
 *   permutation-proof rather than order-restoring. `orderSafe` decides ONE thing —
 *   this right-hand side resolves NOTHING declared in this class — and a chained
 *   candidate is accepted only when it holds for the candidate AND for every init
 *   that shares the prologue with it: the sole-write ones accepted on the legacy
 *   path, and the fields that ALREADY carry a declaration initializer. Read what
 *   that establishes carefully, because it is stronger than it first looks: NOT "no
 *   init reads a member another init assigns" (Haxe already forbids an initializer
 *   from touching another instance member, which would make the gate vacuous), but
 *   NO INIT IN THAT PROLOGUE DIRECTLY READS IN-CLASS STATE AT ALL, hence none can
 *   observe an in-class static that another one's FOREIGN CODE writes. That is why
 *   a plain `_a:Int = s` beside a chained `_b = new Bar()` is refused even though
 *   neither one mentions the other. Covering the pre-existing initializers is also
 *   what makes `--fix` safe to run to a FIXPOINT: a candidate one pass refuses
 *   cannot be unblocked by the co-mover that same pass moved out.
 *
 * The sole-write path is otherwise UNCHANGED and joins no chain: with `writeCount == 1`
 * the moved statement is the field's only assignment whatever precedes it. It does,
 * however, count as a CO-MOVER — a sole-write init that reads in-class state refuses
 * every chained candidate in the same constructor. The unresolved-write bail, the
 * read-before-init gate, the reachable-prefix gate and the base-constructor gate apply to
 * both paths.
 *
 * ## Known gaps
 *
 * `orderSafe` decides what a right-hand side READS, never what the code it invokes
 * DOES. The gaps that remain are therefore about effects rather than references:
 *
 * - Foreign code reachable from a moved right-hand side may mutate ANY state — an
 *   external global or an in-class static alike (`new Foo()` whose constructor
 *   assigns `A.s`). `orderSafe` cannot see through the call, and the mutation is
 *   reordered along with the move.
 * - A moved right-hand side and any OTHER init sharing the prologue can communicate
 *   through such state and still swap — a second moved right-hand side, or a
 *   PRE-EXISTING declaration initializer, either will do. On the chain path both are
 *   gated; on the sole-write path neither is.
 * - The SOLE-WRITE path is gated by neither of those, and its remaining exposure is
 *   not co-movers at all: it reorders against ARBITRARY EARLIER STRAIGHT-LINE
 *   CONSTRUCTOR STATEMENTS. `new() { s = 5; _a = s; }` and
 *   `new() { _b = bump(); _a = n; }` both fire and both change behaviour, unchanged
 *   from before the chain existed. What it can no longer do is hop an EARLY EXIT, a
 *   never-ending loop or an explicit `super(…)` — `ctorPrefixUnconditional` refuses a
 *   prefix it cannot prove completes and `ctorCallsSuper` refuses a constructor that
 *   calls up, on BOTH paths. A BRANCH it CAN hop: an `if` / `switch` / `try` / `#if`
 *   holding neither an exit nor a loop is admitted, since control leaves it either
 *   way. The CHAIN path is stricter still: any non-candidate statement breaks the
 *   chain, where the legacy path only asks that the prefix be reached.
 *
 * The in-class veto is also deliberately coarse: an IMMUTABLE static (`static
 * inline`, `static final`) can never be the channel these gaps describe, yet reading
 * one still refuses a chained candidate. Measured cost is zero on the trees checked,
 * so the distinction is left unmade — it is the obvious first relaxation if that
 * changes.
 *
 * Emission order is an OBSERVATION, not a contract: field initializers ran in reverse
 * declaration order on `--interp` and `js`; hxcpp was not measured. Nothing above
 * depends on the direction — `orderSafe` holds under any permutation — so a target
 * that emits forward changes none of these statements.
 *
 * ## Fixpoint chain
 *
 * This rule moves the init to the declaration; the EXISTING decl-assigned cases
 * of `prefer-final-field` (private) and `prefer-final-public-field` (public) then
 * catch the now decl-initialized `var` and rewrite it to `final`. Both rules also
 * independently handle `var` and `final` fields, so any pass ordering converges
 * to the same fixpoint. On the CHAIN path there is deliberately no such chaining:
 * the field keeps a write outside its declaration, so it stays a `var` and neither
 * `final` rule flags it — the fixed point is simply one step shorter.
 *
 * ## Scope
 *
 * STATIC fields are out of scope (a static's init timing is unrelated to instance
 * construction). A property (`var x(get, set)`) and a function-type field are
 * skipped (a `(` in the declaration head — a conservative over-skip). A
 * multiple-constructor (macro-generated) class is skipped: only a plain single `new`
 * qualifies, so the init timing stays unambiguous. A `#if`-guarded field IS a candidate —
 * the container walk descends into the region — but only through the SOLE-write path: a
 * region among the container's members still refuses every CHAINED candidate, because the
 * chain's order proof needs one build's member sequence and a region's branches are several.
 * A field name declared in two mutually exclusive branches is refused outright (its rival
 * declarations share one constructor statement, and the move deletes that statement for
 * both). A field whose write count differs from one qualifies only through the
 * chain; an UNRESOLVED write to the field NAME disqualifies it on either path.
 *
 * ## Write shapes
 *
 * Two write shapes qualify, differing in what the FIX does rather than in what it proves. A
 * top-level constructor STATEMENT (`soleConstructorFieldInit`) moves whole: the declaration gains
 * the initializer and the statement’s line goes. An EMBEDDED assignment
 * (`RefactorSupport.soleConstructorFieldWrite`) is an assignment EXPRESSION whose value is consumed
 * where it stands — `super([_a = new Row(…)], …)`, the layout-tree idiom — so the statement holding
 * it must SURVIVE: the fix moves the right-hand side to the declaration and collapses the
 * expression to the field name, a read of what the prologue has by then initialised. Deleting its
 * line would delete live code, which is why the two shapes cannot share one edit path.
 *
 * An embedded write additionally owes `RefactorSupport.ctorWriteUnconditional`, a positive
 * whitelist of the node kinds through which an operand is evaluated exactly once. That sibling
 * predicate admits a write in a ternary arm, an `&&` operand or a loop body, because Haxe accepts
 * those for a `final` field; hoisting one into the always-run prologue would turn a conditional
 * initialisation unconditional, so this rule demands the stricter position. An embedded write also
 * joins NO chain and needs none: the chain keys a candidate by the top-level statement it owns and
 * several embedded writes share one (every element of a single `super([…])` argument), while the
 * enclosing statement stays put, so the SOLE-write proof carries the move exactly as it does for a
 * `#if`-guarded field.
 *
 * `hoistCrossesSuper` refines the base-constructor gate for one shape `ctorCallsSuper` refused
 * wholesale: a write inside the SOLE `super(...)` call’s own ARGUMENT region. Arguments are
 * evaluated in order to pass them, so such a write already runs before the base constructor body,
 * and moving it to the prologue keeps it on that same side. Everything else still refuses — a
 * second super call anywhere (the lexical comparison stops meaning anything), a write outside the
 * argument region, an unrecognisable call.
 *
 * `contextFreeRhs`’s unresolved-name arm is decided from POSITIVE evidence: under `extends`, a
 * lowercase name the single-file resolver cannot bind is admitted when the file EXPLICITLY imports
 * it as a static (`SymbolIndex.fileImportsMemberName`). The absence proof that first suggests
 * itself — no ancestor DECLARES the name — is unsound here, because declaration absence is exactly
 * what a `@:build` / `@:autoBuild` macro undoes: openfl carries one on `Sprite`, so every display
 * subclass in an openfl app sits under an injector, and a real tree offered
 * `onEnable = changeEnabled - true` as movable on the strength of such a proof, where
 * `changeEnabled` is macro-generated and a declaration initializer may not read it at all. See
 * `inheritedProbe` for the residual.
 */
@:nullSafety(Strict)
final class FieldInitAtDeclaration implements Check {

	/**
	 * `file#field` keys already reported by `fix`'s skip diagnostic — one line per
	 * field per process. `lint --fix` re-runs the rule until it reaches a fixpoint, so
	 * an undeduplicated line would repeat once per pass.
	 */
	private static final skipsReported: Array<String> = [];

	public function new() {}

	public function id(): String {
		return 'field-init-at-declaration';
	}

	public function description(): String {
		return 'an instance field initialised with a context-free constant in the constructor that can move to its declaration';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final writeIndex: FieldWriteIndex = FieldWriteIndex.build(files, plugin);
		final lazyIndex: () -> Null<SymbolIndex> = RefactorSupport.lazySymbolIndex(files, plugin);
		final classLike: Array<String> = RefactorSupport.classLikeContainerKinds(shape);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = try plugin.parseFile(entry.source) catch (_: Exception) null;
			if (tree != null) walk(tree, entry.file, entry.source, shape, classLike, writeIndex, lazyIndex, violations);
		}
		return violations;
	}

	/**
	 * Move each flagged field's constructor init onto its declaration: insert
	 * ` = <rhs>` before the declaration's terminating `;` and delete the constructor
	 * statement's whole line. The edits are re-derived from the violation span so
	 * `fix` needs no state carried from `run`.
	 *
	 * A violation is SKIPPED when a candidate-shaped init sits before it in the
	 * constructor and that init's field is not itself in this call's violation list.
	 * `run` accepts a chained candidate only because its whole prefix moves with it, and
	 * a list can arrive thinned — a `// noqa` on one declaration, an overlap filter,
	 * a caller passing a subset. Moving the later init alone would hop it over a
	 * right-hand side that stays put, which is exactly the reordering the chain exists
	 * to prevent.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (_: Exception) null;
		if (tree == null) return [];
		final moving: Array<Int> = [];
		for (v in violations) {
			final vSpan: Null<Span> = v.span;
			if (vSpan != null) moving.push(vSpan.from);
		}
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final loc: Null<{
				container: QueryNode,
				field: QueryNode,
				stmt: QueryNode,
				rhs: QueryNode,
				target: Span
			}> = RefactorSupport.constructorFieldInitAt(tree, span.from, shape);
			if (loc != null) {
				final rhsSpan: Null<Span> = loc.rhs.span;
				final fieldSpan: Null<Span> = loc.field.span;
				final stmtSpan: Null<Span> = loc.stmt.span;
				if (rhsSpan == null || fieldSpan == null || stmtSpan == null) continue;
				if (!prefixMovesTogether(loc.container, stmtSpan.from, moving, source, shape, inheritedProbe(v.file, () -> index))) {
					reportSkip(v.file, loc.field.name);
					continue;
				}
				final insertPos: Int = RefactorSupport.fieldDeclInitInsertPos(source, fieldSpan);
				edits.push({ span: new Span(insertPos, insertPos), text: ' = ${source.substring(rhsSpan.from, rhsSpan.to)}' });
				edits.push({ span: RefactorSupport.lineExtendedSpan(source, stmtSpan), text: '' });
				continue;
			}
			// The EMBEDDED shape: the assignment's value is consumed where it stands, so the statement
			// holding it must SURVIVE. Two edits instead of insert-plus-delete-line: the declaration
			// gains ` = <rhs>` as before, and the assignment expression collapses to the target text
			// it was assigning — `_a = new Row(…)` becomes `_a`, a read of the field the prologue has
			// by then initialised.
			final emb: Null<{
				container: QueryNode,
				field: QueryNode,
				assign: QueryNode,
				rhs: QueryNode,
				target: Span
			}> = embeddedFieldWriteAt(tree, span.from, shape);
			if (emb == null) continue;
			final rhsSpan: Null<Span> = emb.rhs.span;
			final fieldSpan: Null<Span> = emb.field.span;
			final assignSpan: Null<Span> = emb.assign.span;
			if (rhsSpan == null || fieldSpan == null || assignSpan == null) continue;
			if (!prefixMovesTogether(emb.container, assignSpan.from, moving, source, shape, inheritedProbe(v.file, () -> index))) {
				reportSkip(v.file, emb.field.name);
				continue;
			}
			final insertPos: Int = RefactorSupport.fieldDeclInitInsertPos(source, fieldSpan);
			edits.push({ span: new Span(insertPos, insertPos), text: ' = ${source.substring(rhsSpan.from, rhsSpan.to)}' });
			edits.push({ span: assignSpan, text: source.substring(emb.target.from, emb.target.to) });
		}
		return edits;
	}

	/** Push the `field-init-at-declaration` violation for an accepted `cand`. */
	private static inline function flag(out: Array<Violation>, file: String, cand: Candidate): Void {
		out.push({
			file: file,
			span: cand.span,
			rule: 'field-init-at-declaration',
			severity: Severity.Info,
			message: 'field \'${cand.name}\' is initialised with a constant in the constructor; move it to the declaration'
		});
	}

	/**
	 * The container, field, assignment node, right-hand side and target span of the EMBEDDED sole
	 * constructor write of the field declared at `fieldFrom` — the `fix`-side counterpart of
	 * `RefactorSupport.constructorFieldInitAt`, which only ever resolves the top-level-statement
	 * shape. Null when the field, its sole constructor and its sole non-closure write are not all
	 * resolvable.
	 */
	private static function embeddedFieldWriteAt(tree: QueryNode, fieldFrom: Int, shape: RefShape): Null<{
		container: QueryNode,
		field: QueryNode,
		assign: QueryNode,
		rhs: QueryNode,
		target: Span
	}> {
		final loc: Null<{ container: QueryNode, field: QueryNode }> = RefactorSupport.classLikeFieldAt(tree, fieldFrom, shape);
		if (loc == null) return null;
		final ctor: Null<QueryNode> = RefactorSupport.soleConstructor(loc.container, shape);
		if (ctor == null) return null;
		final write: Null<{ assign: QueryNode, rhs: QueryNode, target: Span }> = RefactorSupport.soleConstructorFieldWrite(
			loc.container, ctor, loc.field, shape
		);
		return write == null ? null : {
			container: loc.container,
			field: loc.field,
			assign: write.assign,
			rhs: write.rhs,
			target: write.target
		};
	}

	/**
	 * Report `name` skipped once per field per process. `lint --fix` re-runs the rule until it
	 * reaches a fixpoint, so an undeduplicated line would repeat once per pass.
	 */
	private static function reportSkip(file: String, name: Null<String>): Void {
		final key: String = '$file#$name';
		if (skipsReported.contains(key)) return;
		skipsReported.push(key);
		stderr('apq fix: field-init-at-declaration: \'$name\' skipped — a prefix candidate is not in the fix set\n');
	}

	/** Walk `node`, considering every class-like container found. */
	private static function walk(
		node: QueryNode, file: String, source: String, shape: RefShape, classLike: Array<String>, writeIndex: FieldWriteIndex,
		lazyIndex: () -> Null<SymbolIndex>, out: Array<Violation>
	): Void {
		if (classLike.contains(node.kind)) considerContainer(node, file, source, shape, writeIndex, lazyIndex, out);
		for (child in node.children) walk(child, file, source, shape, classLike, writeIndex, lazyIndex, out);
	}

	/**
	 * Flag every movable field of `container` whose constructor init can move to its
	 * declaration. Collects the candidates — one plain constructor, the field
	 * non-static / non-property / no-init, its sole top-level constructor assignment the
	 * only one, no unresolved write to its name, a context-free right-hand side, no read
	 * before the init — then decides acceptance in two passes, because it is
	 * interdependent. Pass one settles the SOLE-WRITE acceptances, which no chain
	 * condition can revoke, and records whether every one of them is `orderSafe`. Pass
	 * two walks the constructor's top-level statements, keying each back to a candidate:
	 * a candidate whose write count differs from one is accepted only while the walk is
	 * still an unbroken run of accepted inits, its own right-hand side resolves nothing
	 * in-class, and so does every sole-write init that will co-move with it. Any other
	 * statement, or a refused candidate, ends the run for everything after it.
	 */
	private static function considerContainer(
		container: QueryNode, file: String, source: String, shape: RefShape, writeIndex: FieldWriteIndex,
		lazyIndex: () -> Null<SymbolIndex>, out: Array<Violation>
	): Void {
		final owner: Null<String> = container.name;
		if (owner == null) return;
		final ctor: Null<QueryNode> = RefactorSupport.soleConstructor(container, shape);
		if (ctor == null) return;
		final mayBeInherited: (String) -> Bool = inheritedProbe(file, lazyIndex);
		final statics: Array<Int> = RefactorSupport.staticMemberFroms(container, shape);
		final found: Candidates = collectCandidates(container, ctor, owner, source, statics, shape, writeIndex, mayBeInherited);
		// An EMBEDDED write joins NO chain, and cannot: the chain keys a candidate by the top-level
		// statement it owns, while several embedded writes share one statement (every element of a
		// single `super([…])` argument). It also needs no chain — the fix leaves that statement standing
		// and rewrites only the assignment expression, so the SOLE-write proof carries the move on its
		// own, exactly as it does for a `#if`-guarded field.
		for (cand in found.embedded) if (cand.sole) flag(out, file, cand);
		var chainOk: Bool = true;
		for (stmt in ctorStatements(ctor, shape)) {
			final stmtSpan: Null<Span> = stmt.span;
			final cand: Null<Candidate> = stmtSpan == null ? null : found.byStmt[stmtSpan.from];
			if (cand == null) {
				chainOk = false;
				continue;
			}
			if (!cand.sole && !(chainOk && found.coMoversOrderSafe && cand.orderSafe)) {
				chainOk = false;
				continue;
			}
			flag(out, file, cand);
		}
	}

	/**
	 * Every candidate of `container`, split by acceptance path: `byStmt` keys the top-level-statement
	 * ones by the statement they own (the chain walk's lookup), `embedded` holds the ones whose write is
	 * an assignment expression owning no statement of its own, and `coMoversOrderSafe` records whether
	 * every init that will share the prologue resolves nothing in-class — the condition a CHAINED
	 * candidate additionally needs, which a sole-write candidate or a pre-existing declaration
	 * initializer can revoke for everyone.
	 *
	 * A field name `container` declares more than once (only reachable across mutually exclusive `#if`
	 * branches) is dropped outright: its rival declarations share one constructor statement, and
	 * choosing a branch is not the fix's to make.
	 */
	private static function collectCandidates(
		container: QueryNode, ctor: QueryNode, owner: String, source: String, statics: Array<Int>, shape: RefShape,
		writeIndex: FieldWriteIndex, mayBeInherited: (String) -> Bool
	): Candidates {
		final byStmt: Map<Int, Candidate> = [];
		final embedded: Array<Candidate> = [];
		final rivalled: Array<String> = rivalDeclaredNames(container, shape);
		var coMoversOrderSafe: Bool = true;
		// Every member host, not just the container's direct children: a field written inside a
		// member-position `#if` sits one level down and was silently exempt.
		RefactorSupport.eachMemberHost(container, host -> {
			for (member in host.children) {
				final cand: Null<Candidate> = candidateFor(
					member, container, ctor, owner, source, statics, shape, writeIndex, mayBeInherited
				);
				if (cand == null) {
					if (coMoverOrderUnsafe(member, container, statics, source, shape, mayBeInherited)) coMoversOrderSafe = false;
					continue;
				}
				if (rivalled.contains(cand.name)) continue;
				if (cand.embedded)
					embedded.push(cand);
				else
					byStmt[cand.stmtFrom] = cand;
			}
		});
		for (cand in byStmt) if (cand.sole && !cand.orderSafe) coMoversOrderSafe = false;
		for (cand in embedded) if (cand.sole && !cand.orderSafe) coMoversOrderSafe = false;
		return {
			byStmt: byStmt,
			embedded: embedded,
			coMoversOrderSafe: coMoversOrderSafe
		};
	}

	/**
	 * A probe answering "could this unresolved lowercase name be a member the container INHERITS?" —
	 * the question `contextFreeRhs` must ask before treating such a name as a global, since a
	 * single-file resolver cannot tell an imported static from an inherited member.
	 *
	 * Answered from POSITIVE evidence only: the file EXPLICITLY imports the name as a static
	 * (`import macros.Lang.t;`), so a bare occurrence binds globally. The tempting alternative —
	 * `typeProvablyLacksMember`, "no ancestor declares this name" — is an ABSENCE proof, and absence is
	 * exactly what a build macro undoes by adding members that exist in no source text. That is not a
	 * corner case: openfl carries `@:autoBuild(AssetsMacro.initBinding())` on `Sprite`, so every display
	 * subclass in an openfl app has an injector above it, and pony's `@:bindable` generates a signal
	 * member per field — a real tree produced `onEnable = changeEnabled - true` as movable on the
	 * strength of such a proof, where `changeEnabled` is macro-generated and a declaration initializer
	 * may not read it at all.
	 *
	 * With no index the answer is "maybe", keeping the blanket veto the rule had before. The residual
	 * is a member that SHADOWS an explicitly imported static of the same name; Haxe rejects the moved
	 * initializer outright in that case ("Cannot access this or other member field in variable
	 * initialization", 4.3.7), so the cost is a loud compile error at the rewritten line, never a silent
	 * behaviour change.
	 */
	private static function inheritedProbe(file: String, lazyIndex: () -> Null<SymbolIndex>): (String) -> Bool {
		return member -> {
			final index: Null<SymbolIndex> = lazyIndex();
			return index == null || !index.fileImportsMemberName(file, member);
		};
	}

	/** The constructor body's top-level statements; empty when the body is not a block. */
	private static function ctorStatements(ctor: QueryNode, shape: RefShape): Array<QueryNode> {
		final bodyKind: Null<String> = shape.blockBodyKind;
		if (bodyKind == null) return [];
		for (child in ctor.children) if (child.kind == bodyKind) return child.children;
		return [];
	}

	/**
	 * `member` as a MOVABLE field — its name and declaration span — or null when it is
	 * not one. Movable means an INSTANCE (non-static) field declaration with no
	 * declaration initializer and no `(` in its head, the conservative over-skip that
	 * bars a property (whose setter would run on assignment) and a function-type field.
	 * Shape only: the write-count, context-free and read-before-init gates belong to
	 * the caller.
	 */
	private static function movableField(
		member: QueryNode, statics: Array<Int>, source: String, shape: RefShape
	): Null<{ name: String, span: Span }> {
		final fields: Array<String> = shape.fieldDeclKinds ?? [];
		if (!fields.contains(member.kind)) return null;
		final span: Null<Span> = member.span;
		final name: Null<String> = member.name;
		return span == null || name == null || statics.contains(span.from) || member.children.length >= 1
			|| source.substring(span.from, span.to).indexOf('(') >= 0
			? null
			: {
				name: name,
				span: span
			};
	}

	/**
	 * The movable field a top-level constructor statement assigns — `x = rhs` /
	 * `this.x = rhs` targeting a `movableField` of `container` — or null for any other
	 * statement. Shape only, so `fix` can recognise a candidate-shaped init without
	 * rebuilding the cross-file write index.
	 */
	private static function assignedMovableField(
		stmt: QueryNode, container: QueryNode, statics: Array<Int>, source: String, shape: RefShape
	): Null<{ name: String, span: Span, rhs: QueryNode }> {
		final stmtKind: Null<String> = shape.exprStatementKind;
		final assignKind: Null<String> = shape.assignKind;
		if (stmtKind == null || assignKind == null || stmt.kind != stmtKind || stmt.children.length < 1) return null;
		final assign: QueryNode = stmt.children[0];
		if (assign.kind != assignKind || assign.children.length < 2) return null;
		final target: QueryNode = assign.children[0];
		for (member in container.children) {
			final mv: Null<{ name: String, span: Span }> = movableField(member, statics, source, shape);
			if (mv != null && denotesMember(target, mv.span.from, mv.name, container, shape)) return {
				name: mv.name,
				span: mv.span,
				rhs: assign.children[1]
			};
		}
		return null;
	}

	/**
	 * Whether every candidate-shaped init before `boundary` in `container`'s sole
	 * constructor is also moving in this `fix` call — its field's declaration start
	 * present in `moving`. A single violation can be suppressed (`// noqa`) or dropped
	 * by an overlap filter, and moving a later init alone would hop it over an init
	 * that stays put, reordering two right-hand sides; the later violation is skipped
	 * instead.
	 */
	private static function prefixMovesTogether(
		container: QueryNode, boundary: Int, moving: Array<Int>, source: String, shape: RefShape, mayBeInherited: (String) -> Bool
	): Bool {
		final ctor: Null<QueryNode> = RefactorSupport.soleConstructor(container, shape);
		if (ctor == null) return false;
		final statics: Array<Int> = RefactorSupport.staticMemberFroms(container, shape);
		for (stmt in ctorStatements(ctor, shape)) {
			final span: Null<Span> = stmt.span;
			if (span == null || span.from >= boundary) continue;
			// The moment a statement `run` could NOT have accepted appears, run's chain is broken
			// there — so whatever sits after it was accepted on the SOLE-write path, which never
			// needed a group proof and hops arbitrary earlier straight-line statements by design.
			// Nothing further to demand.
			final mv: Null<{ name: String, span: Span, rhs: QueryNode }> = acceptableCoMover(
				stmt, container, ctor, source, statics, shape, mayBeInherited
			);
			if (mv == null) return true;
			if (!moving.contains(mv.span.from)) return false;
		}
		return true;
	}

	/**
	 * `stmt` as an init `run` would have accepted as part of a CHAIN, judged by the acceptance gates
	 * that are decidable from `source` alone — candidate shape, a context-free right-hand side, a
	 * reachable prefix, no read of the field before the init, and no hoist across a base-constructor
	 * call. Null when any of them fails.
	 *
	 * The one gate NOT replicated is the cross-file write count, which needs a `FieldWriteIndex`
	 * `fix` does not receive; a field whose count differs is therefore read here as chained when
	 * `run` may have refused it outright. That direction only ever keeps the guard armed one
	 * statement longer, so it can over-decline a fix but never mis-apply one — and it is the reason
	 * this cannot simply call `candidateFor`.
	 */
	private static function acceptableCoMover(
		stmt: QueryNode, container: QueryNode, ctor: QueryNode, source: String, statics: Array<Int>, shape: RefShape,
		mayBeInherited: (String) -> Bool
	): Null<{ name: String, span: Span, rhs: QueryNode }> {
		final mv: Null<{ name: String, span: Span, rhs: QueryNode }> = assignedMovableField(stmt, container, statics, source, shape);
		final span: Null<Span> = stmt.span;
		if (mv == null || span == null) return null;
		if (!contextFreeRhs(mv.rhs, container, statics, shape, true, mayBeInherited)) return null;
		if (!RefactorSupport.ctorPrefixUnconditional(ctor, span.from, shape)) return null;
		if (hoistCrossesSuper(ctor, container, span.from, shape)) return null;
		return readBeforeInit(ctor, mv.span.from, mv.name, span.from, container, shape) ? null : mv;
	}

	/**
	 * Whether `node` denotes the member of `container` declared at `memberFrom` under
	 * `memberName` — a bare identifier resolving to that binding (so a same-named local
	 * or parameter is rejected), or `this.<memberName>`.
	 */
	private static function denotesMember(
		node: QueryNode, memberFrom: Int, memberName: String, container: QueryNode, shape: RefShape
	): Bool {
		final identKind: String = shape.identKind;
		final faKind: Null<String> = shape.fieldAccessKind;
		final selfText: Null<String> = shape.selfReferenceText;
		if (node.name != memberName) return false;
		if (node.kind == identKind) {
			final span: Null<Span> = node.span;
			return span != null && TypeResolver.resolveBindingFrom(memberName, span, container, shape) == memberFrom;
		}
		if (faKind == null || node.kind != faKind || selfText == null) return false;
		final recv: Null<QueryNode> = node.children.length > 0 ? node.children[0] : null;
		return recv != null && recv.kind == identKind && recv.name == selfText;
	}

	/**
	 * The binding-span starts of `container`'s members preceded by a `Static`
	 * modifier sibling — the static members a right-hand side may safely reference.
	 * Whether every identifier read in `node` is context-independent: a global / type /
	 * imported name (unresolved within the class) or a static member of the class — a
	 * value available at declaration-init time — and the subtree contains no `this`. A
	 * reference that resolves within the class but is not static (a constructor parameter
	 * or local, or a non-static instance member) makes the init order-dependent and thus
	 * unmovable, since a static member is the only in-class binding whose value exists
	 * before the constructor body runs.
	 */
	private static function contextFreeRhs(
		node: QueryNode, container: QueryNode, statics: Array<Int>, shape: RefShape, allowStatics: Bool, mayBeInherited: (String) -> Bool
	): Bool {
		final identKind: String = shape.identKind;
		final selfText: Null<String> = shape.selfReferenceText;
		// `$p` inside a single-quoted string projects as the interp `Ident` kind, not
		// `IdentExpr` - it is a reference all the same, and the resolver binds it by the
		// same scope rules, so the two share one arm (`${p}` blocks carry a regular
		// IdentExpr child and were already reached by the child walk).
		if (node.kind == identKind || node.kind == shape.stringInterpIdentKind) {
			final name: Null<String> = node.name;
			final span: Null<Span> = node.span;
			if (name == null || span == null) return false;
			if (selfText != null && name == selfText) return false;
			final bf: Null<Int> = TypeResolver.resolveBindingFrom(name, span, container, shape);
			// An unresolved ident is the provably-global case (imports/statics) - UNLESS the
			// container has a supertype clause: an INHERITED member is invisible to the
			// single-file resolver and indistinguishable from a global, so under `extends` /
			// `implements` an unresolved lowercase ident fails closed too (type refs like
			// `Colors.WHITE` keep their uppercase root and stay movable).
			if (bf != null) return allowStatics && statics.contains(bf);
			if (!hasSupertype(container, shape)) return true;
			final c0: Int = StringTools.fastCodeAt(name, 0);
			// An uppercase root is a TYPE reference (`Colors.WHITE`) — never an inherited member, and
			// decided without touching the index. A lowercase one asks the index whether any ancestor
			// could declare it.
			return c0 >= 'A'.code && c0 <= 'Z'.code || !mayBeInherited(name);
		}
		for (child in node.children) if (!contextFreeRhs(child, container, statics, shape, allowStatics, mayBeInherited)) return false;
		return true;
	}

	/**
	 * Whether the field is referenced anywhere in the constructor BEFORE its
	 * initializing statement. Any such reference is a READ: whichever shape resolved the
	 * candidate demanded a SINGLE match — `soleConstructorFieldInit` over the top-level
	 * statements, `RefactorSupport.soleConstructorFieldWrite` over the whole constructor
	 * subtree — so no second write to the field can precede this one. Moving the init ahead of
	 * the constructor body would change the observed value, so the candidate is
	 * rejected. Detects a direct reference — a bare identifier resolving to the field,
	 * or `this.field`; a read reached only through a preceding method call (including a
	 * `super()` virtual dispatch) is not detected, which is why the chain bars both
	 * shapes from an accepted prefix (see the class doc).
	 */
	private static function readBeforeInit(
		node: QueryNode, fieldFrom: Int, fieldName: String, boundary: Int, container: QueryNode, shape: RefShape
	): Bool {
		final span: Null<Span> = node.span;
		if (span != null && span.from < boundary && denotesMember(node, fieldFrom, fieldName, container, shape)) return true;
		for (child in node.children) if (readBeforeInit(child, fieldFrom, fieldName, boundary, container, shape)) return true;
		return false;
	}

	/**
	 * Whether the container carries any supertype clause (`extends` /
	 * `implements`) - the condition under which an unresolved bare ident may
	 * actually be an inherited member rather than a global.
	 */
	private static function hasSupertype(container: QueryNode, shape: RefShape): Bool {
		final clauses: Array<String> = shape.supertypeClauseKinds ?? [];
		if (clauses.length == 0) return false;
		for (c in container.children) if (clauses.contains(c.kind)) return true;
		return false;
	}


	/**
	 * Whether hoisting the write at `writeFrom` into the declaration prologue would cross an explicit
	 * base-constructor call. Haxe emits declaration initializers ahead of the constructor BODY, and an
	 * explicit `super(...)` lives inside that body, so an init moved across one runs before the base
	 * constructor has set up whatever it reads.
	 *
	 * The coarse question — does this constructor call up at all — is what the class doc argues for,
	 * because "the init precedes THE super call" usually has no answer: the call can sit in a branch and
	 * appear more than once. ONE shape does have an answer, and it is the layout-tree idiom this rule was
	 * extended for: a write inside the sole call's own ARGUMENT region. Arguments are evaluated in order
	 * to pass them, so such a write already runs before the base constructor body, and moving it to the
	 * prologue keeps it on that same side — it then crosses only the constructor's own preceding
	 * statements, which `contextFreeRhs` and the chain gates already cover.
	 *
	 * Everything else refuses: more than one super call, a write outside the argument region, and any
	 * grammar whose seams leave the call unrecognisable. A `super.foo()` is deliberately not a call up —
	 * it is a base-MEMBER access, which the prologue does not race — and `collectSuperCalls` excludes it
	 * by requiring the callee to be the bare `super` identifier rather than a field access on it.
	 */
	private static function hoistCrossesSuper(ctor: QueryNode, container: QueryNode, writeFrom: Int, shape: RefShape): Bool {
		final superText: Null<String> = shape.superReferenceText;
		final callKind: Null<String> = shape.callKind;
		// With either seam unset the base-constructor call cannot be recognised at all, so the answer
		// falls back to `hasSupertype` — coarser, refusing every subclass rather than only the ones that
		// call up. Closed only while `supertypeClauseKinds` is itself declared: with that seam unset too,
		// `hasSupertype` is false for every container and this gate is ABSENT rather than coarser. The
		// three seams are optional independently, so a grammar declaring none disarms it entirely;
		// `HaxeQueryPlugin` declares all three.
		if (superText == null || callKind == null) return hasSupertype(container, shape);
		final calls: Array<QueryNode> = [];
		collectSuperCalls(ctor, superText, callKind, shape.identKind, calls);
		// No call up at all: the prologue crosses nothing. Several: they can sit on different branches,
		// so "the write precedes THE super call" has no answer and the gate refuses.
		if (calls.length == 0) return false;
		if (calls.length != 1) return true;
		final callSpan: Null<Span> = calls[0].span;
		final calleeSpan: Null<Span> = calls[0].children[0].span;
		return callSpan == null || calleeSpan == null || writeFrom < calleeSpan.to || writeFrom >= callSpan.to;
	}

	/** Collect every call in `node`'s subtree whose callee is the bare identifier `superText`. */
	private static function collectSuperCalls(
		node: QueryNode, superText: String, callKind: String, identKind: String, out: Array<QueryNode>
	): Void {
		if (node.kind == callKind && node.children.length > 0) {
			final callee: QueryNode = node.children[0];
			if (callee.kind == identKind && callee.name == superText) out.push(node);
		}
		for (child in node.children) collectSuperCalls(child, superText, callKind, identKind, out);
	}

	/** Guarded stderr write — mirrors `LintConfig.stderr` (`#if sys` alone is false on hxnodejs). */
	private static function stderr(s: String): Void {
		#if (sys || nodejs)
		Sys.stderr().writeString(s);
		#end
	}

	/**
	 * Whether a NON-candidate member makes the constructor prologue order-unsafe for a
	 * chained candidate. Two arms:
	 *
	 * - a `#if` member REGION. The projection keeps its interior as trivia, so a
	 *   declaration initializer declared inside it is invisible here — the arm fails
	 *   closed and refuses the whole container. (An `#if` inside an initializer
	 *   EXPRESSION is a different node whose children are real; the second arm walks it
	 *   normally.)
	 * - an instance field carrying a DECLARATION initializer that resolves something
	 *   in-class. Such an initializer already shares the prologue a chained candidate
	 *   would move into, so it co-moves in effect: if it reads a class member, an init
	 *   arriving beside it can perturb what it observes.
	 *
	 * A static is excluded (its initializer runs with the type, not the instance), and so
	 * is a member with no initializer.
	 */
	private static function coMoverOrderUnsafe(
		member: QueryNode, container: QueryNode, statics: Array<Int>, source: String, shape: RefShape, mayBeInherited: (String) -> Bool
	): Bool {
		if (RefactorSupport.isConditionalKind(member.kind)) return true;
		final fields: Array<String> = shape.fieldDeclKinds ?? [];
		final span: Null<Span> = member.span;
		return span != null && fields.contains(member.kind) && !statics.contains(span.from) && member.children.length >= 1
			&& !contextFreeRhs(member.children[0], container, statics, shape, false, mayBeInherited);
	}

	/**
	 * `member` as a chain CANDIDATE — a movable field whose sole top-level constructor
	 * assignment passes every gate that does not depend on the other candidates: no
	 * unresolved write to its name, a context-free right-hand side, and no read of the
	 * field before that statement. Records the init statement's start (the key the
	 * chain walk looks it up by), whether the right-hand side resolves nothing in-class
	 * and whether the field's cross-file write count is one. Null when `member` is not
	 * one.
	 */
	private static function candidateFor(
		member: QueryNode, container: QueryNode, ctor: QueryNode, owner: String, source: String, statics: Array<Int>, shape: RefShape,
		writeIndex: FieldWriteIndex, mayBeInherited: (String) -> Bool
	): Null<Candidate> {
		final mv: Null<{ name: String, span: Span }> = movableField(member, statics, source, shape);
		if (mv == null) return null;
		final write: Null<{ rhs: QueryNode, at: Span, embedded: Bool }> = ctorWriteFor(container, ctor, member, shape);
		if (write == null || writeIndex.hasUnresolvedWrite(mv.name)) return null;
		final at: Int = write.at.from;
		// An embedded write may sit in a LAZILY evaluated operand (a ternary arm, an `&&` right side, a
		// loop body) — shapes `soleConstructorFieldWrite` admits because Haxe accepts them for a `final`
		// field. Hoisting one into the always-run prologue would make a conditional initialisation
		// unconditional, so the move demands the separate whitelist proof.
		if (write.embedded && !RefactorSupport.ctorWriteUnconditional(ctor, at, shape)) return null;
		// Gating the CANDIDATE rather than one of the two acceptance paths is what makes both
		// inherit it: the chain path already demanded an unbroken run of accepted inits, so
		// this is a no-op there, and the sole-write path — which looks at no prefix at all —
		// is the one that needed it.
		if (!RefactorSupport.ctorPrefixUnconditional(ctor, at, shape)) return null;
		// Haxe emits declaration initializers ahead of the constructor BODY, an explicit `super()`
		// included, so no init may be hoisted across one — except one written INSIDE that call's own
		// arguments, which already runs before it. Gated on the CANDIDATE for the same reason as the
		// line above, so both acceptance paths inherit it from one place.
		if (hoistCrossesSuper(ctor, container, at, shape)) return null;
		final unsafeRead: Bool = readBeforeInit(ctor, mv.span.from, mv.name, at, container, shape);
		return !contextFreeRhs(write.rhs, container, statics, shape, true, mayBeInherited) || unsafeRead ? null : {
			name: mv.name,
			stmtFrom: at,
			span: mv.span,
			orderSafe: contextFreeRhs(write.rhs, container, statics, shape, false, mayBeInherited),
			sole: writeIndex.writeCount(owner, mv.name) == 1,
			embedded: write.embedded
		};
	}

	/**
	 * The constructor write that initialises `member`, as its right-hand side, the span the move
	 * anchors on and whether it is EMBEDDED. Takes the top-level-statement shape first — whose anchor
	 * is the whole statement, since the fix deletes it — and the embedded shape second, anchored on the
	 * assignment expression the fix rewrites in place. Null when neither resolves.
	 */
	private static function ctorWriteFor(
		container: QueryNode, ctor: QueryNode, member: QueryNode, shape: RefShape
	): Null<{ rhs: QueryNode, at: Span, embedded: Bool }> {
		final init: Null<{ stmt: QueryNode, rhs: QueryNode, target: Span }> = RefactorSupport.soleConstructorFieldInit(
			container, ctor, member, shape
		);
		if (init != null) {
			final stmtSpan: Null<Span> = init.stmt.span;
			return stmtSpan == null ? null : {
				rhs: init.rhs,
				at: stmtSpan,
				embedded: false
			};
		}
		final write: Null<{ assign: QueryNode, rhs: QueryNode, target: Span }> = RefactorSupport.soleConstructorFieldWrite(
			container, ctor, member, shape
		);
		if (write == null) return null;
		final assignSpan: Null<Span> = write.assign.span;
		return assignSpan == null ? null : {
			rhs: write.rhs,
			at: assignSpan,
			embedded: true
		};
	}

	/**
	 * The member names `container` declares MORE THAN ONCE — only reachable across mutually
	 * exclusive `#if` branches, since one container cannot declare a name twice in one build.
	 *
	 * Such a field is refused outright. Its rival declarations share ONE constructor statement, and
	 * only one of them is the binding the statement resolves to: the move would land the initializer
	 * on that declaration and delete the statement for BOTH branches, leaving the other branch's
	 * field never initialised. Choosing a branch is not the fix's to make.
	 */
	private static function rivalDeclaredNames(container: QueryNode, shape: RefShape): Array<String> {
		final members: Array<String> = shape.memberDeclKinds ?? [];
		final seen: Array<String> = [];
		final duplicated: Array<String> = [];
		RefactorSupport.eachMemberHost(container, host -> {
			for (child in host.children) if (members.contains(child.kind)) {
				final name: Null<String> = child.name;
				if (name == null) continue;
				if (seen.contains(name) && !duplicated.contains(name)) duplicated.push(name);
				seen.push(name);
			}
		});
		return duplicated;
	}

}

/**
 * One accepted-or-rejectable constructor init: the field's `name` and declaration
 * `span`, whether its right-hand side resolves nothing in-class (`orderSafe`) and
 * whether the field's cross-file write count is one (`sole`, the legacy path).
 */
private typedef Candidate = {
	var name: String;
	var stmtFrom: Int;
	var span: Span;
	var orderSafe: Bool;
	var sole: Bool;
	var embedded: Bool;
}

/**
 * `container`'s candidates split by acceptance path — `byStmt` keyed by the top-level statement each
 * owns, `embedded` owning none — plus whether every prologue co-mover is `orderSafe`.
 */
private typedef Candidates = {
	var byStmt: Map<Int, Candidate>;
	var embedded: Array<Candidate>;
	var coMoversOrderSafe: Bool;
}

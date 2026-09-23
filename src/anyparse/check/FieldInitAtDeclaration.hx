package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.CondRegionScan;
import anyparse.query.CtorFieldFold.DeclaredType;
import anyparse.query.CtorFieldWrite;
import anyparse.query.ElementSpan;
import anyparse.query.FieldWriteIndex;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;
import anyparse.query.RawSourceScan;
import anyparse.query.RefactorSupport;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.query.SymbolIndexHost;
import anyparse.query.TreePath;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;
using Lambda;

/**
 * Flags an INSTANCE field (`var` or `final`) that has NO declaration initializer but
 * whose write is one unconditional constructor assignment `x = expr` / `this.x = expr`
 * whose right-hand side is context-independent
 * (references no constructor parameters, no `this`, no other instance members, no
 * constructor locals and no static of this very type — only literals,
 * FOREIGN static / global references, and constructions such as `new Shape()`).
 * `Severity.Info`, with an autofix that MOVES `= expr` onto the field declaration
 * and removes the constructor write — e.g.
 * `private var _a:Array<Int>;` + constructor `_a = new Array<Int>();` becomes
 * `private var _a:Array<Int> = new Array<Int>();`.
 *
 * ## Soundness — why the move is order-safe
 *
 * A declaration initializer runs BEFORE the constructor body, so moving an init
 * earlier is safe only when the moved expression does not depend on anything the
 * constructor establishes first. The context-free right-hand-side gate guarantees
 * exactly that: every identifier read resolves to a global or a FOREIGN type's member — a
 * value the constructor of THIS type cannot have touched — never to a constructor parameter
 * or local (which do not exist yet), another instance member (a field that may be
 * uninitialized), `this`, or a static of this type (whose VALUE the constructor may set one
 * statement before the init reads it; `final` on such a static proves only that the BINDING
 * is fixed, and the live regression read `ns[0]` from a `static final` array the constructor
 * had yet to fill). Combined with the exactly-one-write proof
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
 * once the init moved onto the declaration (4.3.7, `--interp`). `hoistCrossesSuper` therefore
 * refuses an init hoisted across the call up (save one the crossing narrowings below admit),
 * and it gates the CANDIDATE for the same reason `ctorPrefixUnconditional` does, so both
 * acceptance paths inherit it. With `superReferenceText` or `callKind` unset the call cannot be
 * recognised at all, and the gate falls back to `RefactorSupport.hasSupertypeClause`, which refuses every subclass — coarser,
 * still closed. That fallback rests on ONE MORE optional seam, and there the gate does degrade
 * OPEN: `hasSupertypeClause` reads `supertypeClauseKinds ?? []` and answers false on an empty
 * list, so a plugin declaring NONE of the three seams gets no gate at all rather than a
 * coarse one. Deliberately not closed in code by making an undeclared
 * `supertypeClauseKinds` refuse every container — that would kill the rule for any language
 * with no inheritance concept. Nothing is exposed today (`HaxeQueryPlugin` sets all three
 * and is the only `RefShape` producer); this paragraph is the contract a future plugin
 * author reads.
 *
 * CROSSING `super(...)`. An init `hoistCrossesSuper` reports as crossing the call up is still
 * accepted on ONE path, when the narrowings of `crossingAdmitted` all hold. The move
 * changes exactly two things: the right-hand side is evaluated before the base constructor,
 * which is harmful the moment it reads or calls anything (the `Loader.ready` regression above);
 * and code the base constructor runs sees the field already initialised instead of `null`.
 * Reachability cannot decide the second — a base constructor may hand `this` to unknown code
 * (openfl's `Sprite` binds it to a library), so any member may run — so the narrowings aim at
 * the second by making an early read FAULT, on top of every candidate gate:
 *
 * - INERT COLLECTION (`inertCollection`): an array, map or object literal of inert elements. A
 *   positive whitelist, so a call, a `new`, an identifier and `null` refuse, and so do a bare
 *   scalar or string: a `null` String answers `length` and `indexOf` on hxcpp instead of
 *   faulting, and a scalar has no member access to fault on.
 * - FAULTING DECLARED TYPE (`faultingFieldType`): no annotation, an anonymous structure,
 *   `Dynamic`, or an unqualified core array / map name the file does not SHADOW
 *   (`coreNameShadowed`: an import, a wildcard, an own, sibling or root-package declaration of
 *   that name). An abstract (whose `@:from` turns the literal into a call, and whose methods may
 *   accept a `null` receiver) or a class refuses.
 * - SOLE writer: the field's write count is one and no unresolved write reaches its name, so no
 *   write the base constructor (or code it calls) makes can survive the assignment the move
 *   deletes. The chain path never crosses: `acceptableCoMover` refuses every crossing init.
 * - PROJECT-CONFINED (`fieldExposed`): the field is not public and its type is not public-by-
 *   default, and the project's declared `resolutionRoots` matched at least one `.hx`, so the
 *   scope below holds every file those roots reach — which is every file that can name the field
 *   only when the roots span the project (see the residuals).
 * - NO OBSERVABLE EARLY READ (`observableRead`): across that scope — a subclass in another file
 *   is a reader too — every occurrence of the name that may denote the field (by NAME, narrowed
 *   only where the binding provably lies elsewhere) is the receiver of a member access, of an
 *   index access, or a callee, and none sits lexically inside a `try` body, a lambda or local
 *   function written there included. Any other position — `==`, `??`, `?.`, an argument, a
 *   `return`, an assignment's right-hand side, a literal element, an interpolation — refuses,
 *   and so does a reflective string spelling the name or a scope file that does not parse.
 *
 * What that establishes is NOT a proof. Before the move an early reader met `null` in a position
 * where it faults and no lexically enclosing `try` could catch it, so such an execution failed;
 * after the move it sees the collection instead. RESIDUAL: the fault can still be caught further
 * out — in a caller of the reader, or in library code between the base constructor and the
 * reader — and a program that relied on that catch changes behaviour. The other
 * residuals: a library reading the field through `Dynamic` lies outside the project
 * scope; a project consumed as a library exposes even a non-public field to downstream
 * subclasses, since Haxe's `private` is visible to them; and `resolutionRoots` that cover only
 * PART of the project (a subclass under a directory no root names) leave that part unscanned —
 * the roots are the user's statement of what the project is, and a narrow lint then disagrees
 * with a whole-project one.
 *
 * A field whose cross-file write count DIFFERS FROM ONE (a `dispose()` null-out, say)
 * can still move, on the ACCEPTED-CANDIDATE CHAIN: every top-level constructor
 * statement before its init must itself be the init of another accepted candidate of
 * the same constructor. Two pillars carry that, and NEITHER is "the prefix runs no
 * foreign code" — foreign code MAY run in an accepted prefix (`new T()` and static
 * calls are context-free), which is exactly why the second pillar is needed:
 *
 * - INSTANCE-UNREACHABILITY. No accepted-prefix right-hand side can leak `this`
 *   (`RefactorSupport.contextFreeRhs` refuses `this` and every in-class non-static
 *   resolution), and no other statement shape is allowed in the prefix — no bare call,
 *   no `super(...)`, no local declaration, no branch or loop. So the second writer of
 *   the field, wherever it lives, cannot be reached in the window the move opens;
 *   `super(...)` is barred precisely because an overridden method invoked from the
 *   SUPERCLASS constructor could write the field.
 * - ORDER-INDEPENDENCE. Moving an init changes WHERE its right-hand side runs
 *   relative to every other init in the constructor prologue: they all land there in
 *   whatever sequence the compiler emits them, which is not the sequence the moved
 *   ones had as statements. The gate is therefore per-right-hand-side and
 *   permutation-proof rather than order-restoring, and it sits on the CANDIDATE: no
 *   accepted init's right-hand side resolves ANYTHING declared in this class, on either
 *   path. A chained candidate additionally needs that of the one prologue occupant which
 *   is not a candidate — a field that ALREADY carries a declaration initializer. Read what
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
 * The sole-write path joins no chain: with `writeCount == 1` the moved statement is
 * the field's only assignment whatever precedes it. It needs no co-mover clause of
 * its own any more — a sole-write init that reads in-class state is not a
 * CANDIDATE at all, and the statement it therefore leaves standing in the constructor
 * breaks the chain for everything after it. The unresolved-write bail, the
 * read-before-init gate, the reachable-prefix gate and the base-constructor gate apply to
 * both paths.
 *
 * ## Known gaps
 *
 * The gate decides what a right-hand side READS, never what the code it invokes
 * DOES. The gaps that remain are therefore about effects rather than references:
 *
 * - Foreign code reachable from a moved right-hand side may mutate ANY state — an
 *   external global or an in-class static alike (`new Foo()` whose constructor
 *   assigns `A.s`). The gate cannot see through the call, and the mutation is
 *   reordered along with the move.
 * - A moved right-hand side and any OTHER init sharing the prologue can communicate
 *   through such state and still swap — a second moved right-hand side, or a
 *   PRE-EXISTING declaration initializer, either will do. Both paths refuse a
 *   right-hand side that READS such state; neither sees a WRITE performed by code it calls.
 * - The SOLE-WRITE path still reorders against ARBITRARY EARLIER STRAIGHT-LINE
 *   CONSTRUCTOR STATEMENTS, but only through effects it cannot see: `new() { s = 5; _a = s; }`
 *   and `new() { _b = bump(); _a = n; }` are now refused outright — each right-hand side
 *   resolves an in-class name — while `new() { Foreign.arm(); _a = Foreign.read(); }` still
 *   fires and still changes behaviour. What it can no longer do is hop an EARLY EXIT or a
 *   never-ending loop — `ctorPrefixUnconditional` refuses a prefix it cannot prove
 *   completes, on BOTH paths — nor an explicit `super(…)` short of the crossing
 *   narrowings above. A BRANCH it CAN hop: an `if` / `switch` / `try` / `#if`
 *   holding neither an exit nor a loop is admitted, since control leaves it either
 *   way. The CHAIN path is stricter still: any non-candidate statement breaks the
 *   chain, where the legacy path only asks that the prefix be reached.
 *
 * The in-class veto is deliberately coarse, and the tempting relaxation is WRONG:
 * `static final` does NOT make a static safe to read. It fixes the BINDING, not the VALUE —
 * `static final ns:Array<Int> = []` is what the live regression read `ns[0]` from, one
 * statement before the constructor filled it. Only an `inline` static (a compile-time
 * constant by construction), or a `final` one whose initializer is a scalar literal, could
 * be exempted; a relaxation keyed on the `final` keyword would reopen the regression.
 * The coarse form costs real trees only a couple of sites, and both are correct refusals —
 * `__contextID = __lastContextID++` and `useWorker = ENABLE` on a `public static var` — so
 * the distinction stays unmade.
 *
 * Emission order is an OBSERVATION, not a contract: field initializers
 * run in reverse declaration order on `--interp` and `js`. Nothing above
 * depends on the direction — the gate holds under any permutation — so a target that
 * emits forward changes none of these statements.
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
 * and moving it to the prologue keeps it on that same side. Everything else answers "crosses" —
 * a second super call anywhere (the lexical comparison stops meaning anything), a write outside the
 * argument region, an unrecognisable call — and is refused unless the crossing paragraph's narrowings all hold.
 *
 * `RefactorSupport.contextFreeRhs`’s unresolved-name arm is decided from POSITIVE evidence: under
 * `extends`, a lowercase name the single-file resolver cannot bind is admitted when the file
 * EXPLICITLY imports it as a static (`SymbolIndex.fileImportsMemberName`). The absence proof
 * that first suggests itself — no ancestor DECLARES the name — is unsound here, because declaration absence is exactly
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
		final classLike: Array<String> = MemberKinds.classLikeContainerKinds(shape);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = try plugin.parseFile(entry.source) catch (_: Exception) null;
			if (tree == null) continue;
			final root: QueryNode = tree;
			final earlyInitSafe: EarlyInitProof = crossingAdmitted.bind(files, plugin, entry.file, entry.source, root);
			walk(tree, entry.file, entry.source, shape, classLike, writeIndex, lazyIndex, earlyInitSafe, violations);
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
		final moving: Array<Int> = RunScan.spanStarts(violations);
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
			}> = CtorFieldWrite.constructorFieldInitAt(tree, span.from, shape);
			if (loc != null) {
				final rhsSpan: Null<Span> = loc.rhs.span;
				final fieldSpan: Null<Span> = loc.field.span;
				final stmtSpan: Null<Span> = loc.stmt.span;
				if (rhsSpan == null || fieldSpan == null || stmtSpan == null) continue;
				if (!prefixMovesTogether(loc.container, stmtSpan.from, moving, source, shape, inheritedProbe(v.file, () -> index))) {
					reportSkip(v.file, loc.field.name);
					continue;
				}
				final insertPos: Int = CtorFieldWrite.fieldDeclInitInsertPos(source, fieldSpan);
				edits.push({ span: new Span(insertPos, insertPos), text: ' = ${source.substring(rhsSpan.from, rhsSpan.to)}' });
				edits.push({ span: ElementSpan.lineExtendedSpan(source, stmtSpan), text: '' });
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
			final insertPos: Int = CtorFieldWrite.fieldDeclInitInsertPos(source, fieldSpan);
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
	 * Whether the child at `index` of `parent` is evaluated where a `null` FAULTS: the receiver of a
	 * member access, of an index access, or the callee of a call. A positive whitelist — every other
	 * position lets a `null` flow on, be compared or be defaulted (`==`, `??`, `?.`, an argument, a
	 * `return`, the right-hand side of an assignment, a literal element).
	 */
	private static inline function faultsOnNull(parent: Null<QueryNode>, index: Int, scan: EarlyReadScan): Bool {
		return parent != null && index == 0 && scan.faultingKinds.contains(parent.kind);
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
		final loc: Null<{ container: QueryNode, field: QueryNode }> = CtorFieldWrite.classLikeFieldAt(tree, fieldFrom, shape);
		if (loc == null) return null;
		final ctor: Null<QueryNode> = CtorFieldWrite.soleConstructor(loc.container, shape);
		if (ctor == null) return null;
		final write: Null<{ assign: QueryNode, rhs: QueryNode, target: Span }> = CtorFieldWrite.soleConstructorFieldWrite(
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
		lazyIndex: () -> Null<SymbolIndex>, earlyInitSafe: EarlyInitProof, out: Array<Violation>
	): Void {
		if (classLike.contains(node.kind)) considerContainer(node, file, source, shape, writeIndex, lazyIndex, earlyInitSafe, out);
		for (child in node.children) walk(child, file, source, shape, classLike, writeIndex, lazyIndex, earlyInitSafe, out);
	}

	/**
	 * Flag every movable field of `container` whose constructor init can move to its
	 * declaration. Collects the candidates — one plain constructor, the field
	 * non-static / non-property / no-init, its sole top-level constructor assignment the
	 * only one, no unresolved write to its name, a right-hand side resolving nothing
	 * outside globals and foreign types, no read before the init — then walks the
	 * constructor's top-level statements, keying each back to a candidate. A SOLE-write
	 * candidate is accepted wherever it sits; one whose write count differs from one is
	 * accepted only while the walk is still an unbroken run of accepted inits and no
	 * pre-existing declaration initializer reads in-class state. Any other statement, or a
	 * refused candidate, ends the run for everything after it.
	 */
	private static function considerContainer(
		container: QueryNode, file: String, source: String, shape: RefShape, writeIndex: FieldWriteIndex,
		lazyIndex: () -> Null<SymbolIndex>, earlyInitSafe: EarlyInitProof, out: Array<Violation>
	): Void {
		final owner: Null<String> = container.name;
		if (owner == null) return;
		final ctor: Null<QueryNode> = CtorFieldWrite.soleConstructor(container, shape);
		if (ctor == null) return;
		final mayBeInherited: (String) -> Bool = inheritedProbe(file, lazyIndex);
		final statics: Array<Int> = MemberKinds.staticMemberFroms(container, shape);
		final found: Candidates = collectCandidates(
			container, ctor, owner, source, statics, shape, writeIndex, mayBeInherited, earlyInitSafe
		);
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
			if (!cand.sole && !(chainOk && found.coMoversOrderSafe)) {
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
	 * every PRE-EXISTING declaration initializer that will share the prologue resolves nothing in-class —
	 * the condition a CHAINED candidate additionally needs. The candidates cannot revoke it: `candidateFor`
	 * already refuses an in-class-reading right-hand side.
	 *
	 * A field name `container` declares more than once (only reachable across mutually exclusive `#if`
	 * branches) is dropped outright: its rival declarations share one constructor statement, and
	 * choosing a branch is not the fix's to make.
	 */
	private static function collectCandidates(
		container: QueryNode, ctor: QueryNode, owner: String, source: String, statics: Array<Int>, shape: RefShape,
		writeIndex: FieldWriteIndex, mayBeInherited: (String) -> Bool, earlyInitSafe: EarlyInitProof
	): Candidates {
		final byStmt: Map<Int, Candidate> = [];
		final embedded: Array<Candidate> = [];
		final rivalled: Array<String> = rivalDeclaredNames(container, shape);
		var coMoversOrderSafe: Bool = true;
		// Every member host, not just the container's direct children: a field written inside a
		// member-position `#if` sits one level down and was silently exempt.
		MemberKinds.eachMemberHost(container, host -> {
			for (member in host.children) {
				final cand: Null<Candidate> = candidateFor(
					member, container, ctor, owner, source, statics, shape, writeIndex, mayBeInherited, earlyInitSafe
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
		final ctor: Null<QueryNode> = CtorFieldWrite.soleConstructor(container, shape);
		if (ctor == null) return false;
		final statics: Array<Int> = MemberKinds.staticMemberFroms(container, shape);
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
	 * that are decidable from `source` alone — candidate shape, a right-hand side resolving nothing
	 * in-class (the same `allowStatics = false` reading `candidateFor` uses; the two must agree, or a
	 * statement `run` refused reads as a chain member here and declines the fix for nothing), a
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
		return if (mv == null || span == null)
			null
		else if (!CtorFieldWrite.contextFreeRhs(mv.rhs, container, statics, shape, false, mayBeInherited))
			null
		else if (!CtorFieldWrite.ctorPrefixUnconditional(ctor, span.from, shape))
			null
		else if (hoistCrossesSuper(ctor, container, span.from, shape))
			null
		else if (readBeforeInit(ctor, mv.span.from, mv.name, span.from, container, shape))
			null
		else
			mv;
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
		return node.children.exists(child -> readBeforeInit(child, fieldFrom, fieldName, boundary, container, shape));
	}

	/**
	 * Whether hoisting the write at `writeFrom` into the declaration prologue would cross an explicit
	 * base-constructor call. Haxe emits declaration initializers ahead of the constructor BODY, and an
	 * explicit `super(...)` lives inside that body, so an init moved across one runs before the base
	 * constructor has set up whatever it reads.
	 *
	 * The question stays coarse — does this constructor call up anywhere but around the write — because
	 * "the init precedes THE super call" usually has no answer: the call can sit in a branch and
	 * appear more than once. ONE shape does have an answer, and it is the layout-tree idiom this rule was
	 * extended for: a write inside the sole call's own ARGUMENT region. Arguments are evaluated in order
	 * to pass them, so such a write already runs before the base constructor body, and moving it to the
	 * prologue keeps it on that same side — it then crosses only the constructor's own preceding
	 * statements, which `contextFreeRhs` and the chain gates already cover.
	 *
	 * Everything else answers "crosses": more than one super call, a write outside the argument region,
	 * and any grammar whose seams leave the call unrecognisable. That answer is final on the chain path
	 * (`acceptableCoMover`), while `candidateFor` still admits a crossing SOLE-write init that
	 * `crossingAdmitted` clears — the class doc's crossing paragraph lists those narrowings and
	 * the residual they leave. A `super.foo()` is deliberately not a call up — it is a
	 * base-MEMBER access, which the prologue does not race — and `collectSuperCalls` excludes it by
	 * requiring the callee to be the bare `super` identifier rather than a field access on it.
	 */
	private static function hoistCrossesSuper(ctor: QueryNode, container: QueryNode, writeFrom: Int, shape: RefShape): Bool {
		final superText: Null<String> = shape.superReferenceText;
		final callKind: Null<String> = shape.callKind;
		// With either seam unset the base-constructor call cannot be recognised at all, so the answer
		// falls back to `RefactorSupport.hasSupertypeClause` — coarser, refusing every subclass rather than only the ones that
		// call up. Closed only while `supertypeClauseKinds` is itself declared: with that seam unset too,
		// `hasSupertypeClause` is false for every container and this gate is ABSENT rather than coarser. The
		// three seams are optional independently, so a grammar declaring none disarms it entirely;
		// `HaxeQueryPlugin` declares all three.
		if (superText == null || callKind == null) return CtorFieldWrite.hasSupertypeClause(container, shape);
		final calls: Array<QueryNode> = [];
		CtorFieldWrite.collectSuperCalls(ctor, superText, callKind, shape.identKind, calls);
		// No call up at all: the prologue crosses nothing. Several: they can sit on different branches,
		// so "the write precedes THE super call" has no answer and the gate refuses.
		if (calls.length == 0) return false;
		if (calls.length != 1) return true;
		final callSpan: Null<Span> = calls[0].span;
		final calleeSpan: Null<Span> = calls[0].children[0].span;
		return callSpan == null || calleeSpan == null || writeFrom < calleeSpan.to || writeFrom >= callSpan.to;
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
		if (CondRegionScan.isConditionalKind(member.kind, shape)) return true;
		final fields: Array<String> = shape.fieldDeclKinds ?? [];
		final span: Null<Span> = member.span;
		return span != null && fields.contains(member.kind) && !statics.contains(span.from) && member.children.length >= 1
			&& !CtorFieldWrite.contextFreeRhs(member.children[0], container, statics, shape, false, mayBeInherited);
	}

	/**
	 * `member` as a CANDIDATE — a movable field whose sole top-level constructor assignment
	 * passes every gate that does not depend on the other candidates: no unresolved write to
	 * its name, a right-hand side that resolves nothing in-class (parameters, locals, instance
	 * members AND statics of this type alike), a reachable straight-line prefix, no explicit
	 * call up crossed (unless the write is sole and `earlyInitSafe` clears the crossing narrowings),
	 * and no read of the field before that statement. Records the init statement's
	 * start (the key the chain walk looks it up by), whether the field's cross-file write count
	 * is one and whether the write is embedded. Null when `member` is not one.
	 */
	private static function candidateFor(
		member: QueryNode, container: QueryNode, ctor: QueryNode, owner: String, source: String, statics: Array<Int>, shape: RefShape,
		writeIndex: FieldWriteIndex, mayBeInherited: (String) -> Bool, earlyInitSafe: EarlyInitProof
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
		if (write.embedded && !CtorFieldWrite.ctorWriteUnconditional(ctor, at, shape)) return null;
		// Gating the CANDIDATE rather than one of the two acceptance paths is what makes both
		// inherit it: the chain path already demanded an unbroken run of accepted inits, so
		// this is a no-op there, and the sole-write path — which looks at no prefix at all —
		// is the one that needed it.
		if (!CtorFieldWrite.ctorPrefixUnconditional(ctor, at, shape)) return null;
		final sole: Bool = writeIndex.writeCount(owner, mv.name) == 1;
		// Haxe emits declaration initializers ahead of the constructor BODY, an explicit `super()`
		// included, so an init hoisted across one runs before the base constructor. That is admitted
		// only on the SOLE-write path and only when the early-init narrowings hold (the class doc's
		// "CROSSING `super(...)`"); the chain path never crosses, since `acceptableCoMover` refuses it.
		if (hoistCrossesSuper(ctor, container, at, shape) && !(sole && earlyInitSafe(member, container, write.rhs))) return null;
		final unsafeRead: Bool = readBeforeInit(ctor, mv.span.from, mv.name, at, container, shape);
		// `allowStatics = false`: an in-class STATIC read is refused along with the parameters, locals
		// and instance members. The permissive spelling was the live regression — a right-hand side
		// reading a static the constructor FILLS one statement earlier (`ns.push(7); _x = ns[0];`)
		// hoisted ahead of that statement and observed the empty value. `final` on the static proves
		// nothing: the binding is immutable, its contents are not. Both acceptance paths inherit the
		// gate from here, so a candidate is order-safe by construction and needs no second tier.
		return !CtorFieldWrite.contextFreeRhs(write.rhs, container, statics, shape, false, mayBeInherited) || unsafeRead ? null : {
			name: mv.name,
			stmtFrom: at,
			span: mv.span,
			sole: sole,
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
		final init: Null<{ stmt: QueryNode, rhs: QueryNode, target: Span }> = CtorFieldWrite.soleConstructorFieldInit(
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
		final write: Null<{ assign: QueryNode, rhs: QueryNode, target: Span }> = CtorFieldWrite.soleConstructorFieldWrite(
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
		MemberKinds.eachMemberHost(container, host -> {
			for (child in host.children) if (members.contains(child.kind)) {
				final name: Null<String> = child.name;
				if (name == null) continue;
				if (seen.contains(name) && !duplicated.contains(name)) duplicated.push(name);
				seen.push(name);
			}
		});
		return duplicated;
	}

	/**
	 * Whether hoisting the SOLE write of `member` (a field of `container`, declared in `file` whose parsed
	 * `tree` and `source` are given) across an explicit `super(...)` passes the early-init narrowings the
	 * class doc lists under "CROSSING `super(...)`": a declared project scope, an inert COLLECTION
	 * literal (`inertCollection`), a declared type whose `null` faults (`faultingFieldType`), a field no
	 * code outside the project can name (`fieldExposed`), no reflective string spelling the name, and no
	 * occurrence across the project scope that may denote the field outside an uncaught null-faulting
	 * position (`observableRead`). A scope file that mentions the name but does not parse, or an unparsed
	 * `#if` region spelling it, refuses: either may hold any occurrence at all.
	 */
	private static function crossingAdmitted(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, file: String, source: String, tree: QueryNode,
		member: QueryNode, container: QueryNode, rhs: QueryNode
	): Bool {
		final shape: RefShape = plugin.refShape();
		final name: Null<String> = member.name;
		final span: Null<Span> = member.span;
		// Without declared `resolutionRoots` a narrow lint holds the report files alone, and a reader in any
		// other project file would go unseen. With them, the roots half excludes the report, so an empty one
		// means the report already IS the project.
		final host: Null<SymbolIndexHost> = plugin is SymbolIndexHost ? cast plugin : null;
		final scope: Null<Array<{ file: String, source: String }>> = host == null || !host.projectRootsMatched()
			? null
			: RefactorSupport.resolutionProjectSourcesOf(plugin) ?? files;
		if (name == null || span == null || host == null || scope == null) return false;
		final declared: DeclaredType = fieldDeclaredType(source, span, name);
		return inertCollection(rhs, plugin, shape) && faultingFieldType(declared, shape) && !coreNameShadowed(host, file, declared, scope)
			&& !fieldExposed(tree, member, container, plugin, shape)
			&& !ReflectionScan.runtimeName(ReflectionScan.reflectionSurface(files, plugin), name)
			&& !readObservableInScope(files, plugin, scope, file, name, span.from);
	}

	/**
	 * Whether `node` is an INERT COLLECTION literal — an array, map or object literal whose every element
	 * is inert (`inertElement`): evaluating it runs no code and reads nothing, and the value it builds is
	 * one whose `null` stand-in faults on every member and index access. A positive whitelist: a scalar or
	 * a string is inert but refused at the top level, since a `null` String or a default scalar answers a
	 * member access on a static target instead of faulting.
	 */
	private static function inertCollection(node: QueryNode, plugin: GrammarPlugin, shape: RefShape): Bool {
		final collectionKinds: Array<Null<String>> = [shape.arrayLiteralKind, shape.objectLiteralKind];
		return collectionKinds.contains(node.kind) && node.children.foreach(c -> inertElement(c, plugin, shape));
	}

	/**
	 * Whether the subtree under `node` holds an occurrence of `scan.name` that may denote the field and is
	 * OBSERVABLE early — outside a null-faulting position, or inside one a lexically enclosing `try`
	 * would catch (`inTry`). An occurrence is an identifier, a member access (plain, `?.`, `!.`) or an
	 * interpolated `$name` spelling the name. The target of a plain assignment in a REPORT file is a write,
	 * not a read, and the write index already counted it (the sole-write conjunct); the same target in any
	 * other scope file is a write that index never saw, and it refuses. `parent` / `index` locate `node` in
	 * its parent and `container` is the nearest enclosing class-like declaration, which decides what a
	 * `this.<name>` denotes. `inTry` is set below a `try` body and KEPT across function and lambda
	 * boundaries, since one written inside the `try` may be called there.
	 */
	private static function observableRead(
		node: QueryNode, parent: Null<QueryNode>, index: Int, container: Null<QueryNode>, inTry: Bool, scan: EarlyReadScan
	): Bool {
		if (
			node.name == scan.name && scan.occurrenceKinds.contains(node.kind) && (inTry || !faultsOnNull(parent, index, scan))
			&& !(scan.writesCounted && parent != null && index == 0 && parent.kind == scan.shape.assignKind)
			&& mayDenoteField(node, container, scan)
		)
			return true;
		final host: Null<QueryNode> = scan.classLike.contains(node.kind) ? node : container;
		final tryNode: Bool = scan.tryKinds.contains(node.kind);
		for (i in 0...node.children.length) {
			final child: QueryNode = node.children[i];
			// NOT cleared at a function or lambda boundary: one written inside the `try` may be called
			// there (`try { f(); }`, `items.iter(i -> …)`), and refusing one stored and called later is
			// the safe direction.
			final childInTry: Bool = inTry || tryNode && child.kind != scan.catchKind;
			if (observableRead(child, node, i, host, childInTry, scan)) return true;
		}
		return false;
	}

	/**
	 * Whether the occurrence `node` MAY denote the field — conservatively true unless it provably binds
	 * elsewhere. A bare identifier binds elsewhere when the resolver binds it to any other declaration (a
	 * local, a parameter, another type's own member); an unresolved one may be the field inherited. A
	 * `this.<name>` binds elsewhere when `container` declares its OWN member of that name — Haxe rejects
	 * redeclaring an inherited field, so such a type is not a subtype of the field's owner. Any other
	 * receiver, and an interpolated `$name`, may denote it.
	 */
	private static function mayDenoteField(node: QueryNode, container: Null<QueryNode>, scan: EarlyReadScan): Bool {
		final shape: RefShape = scan.shape;
		final span: Null<Span> = node.span;
		if (node.kind == shape.identKind) {
			final binding: Null<Int> = span == null ? null : TypeResolver.resolveBindingFrom(scan.name, span, scan.tree, shape);
			return binding == null || scan.file == scan.fieldFile && binding == scan.fieldFrom;
		}
		final recv: Null<QueryNode> = node.children.length > 0 ? node.children[0] : null;
		final selfText: Null<String> = shape.selfReferenceText;
		if (container == null || recv == null) return true;
		if (recv.kind != shape.identKind || recv.name != selfText) return true;
		final memberKinds: Array<String> = shape.memberDeclKinds ?? [];
		var own: Null<Int> = null;
		MemberKinds.eachMemberHost(container, host -> for (member in host.children) if (
			member.name == scan.name && memberKinds.contains(member.kind)
		)
			own = member.span?.from);
		return own == null || scan.file == scan.fieldFile && own == scan.fieldFrom;
	}

	/**
	 * Whether `node` is an inert ELEMENT of a collection literal: a scalar literal
	 * (`ConstantFieldScan.isConstantScalarInitializer`), a string literal with no interpolation, a map
	 * entry or object field of inert parts, or a nested inert collection. A call, a `new`, an identifier,
	 * `null`, a lambda and every kind not named here are not inert.
	 */
	private static function inertElement(node: QueryNode, plugin: GrammarPlugin, shape: RefShape): Bool {
		if (ConstantFieldScan.isConstantScalarInitializer(node, plugin)) return true;
		if ((shape.stringLiteralKinds ?? []).contains(node.kind)) {
			final textKind: Null<String> = shape.stringInterpTextKind;
			final inertSegments: Array<String> = shape.stringInterpInertSegmentKinds ?? [];
			return node.children.foreach(c -> c.kind == textKind || inertSegments.contains(c.kind));
		}
		final partKinds: Array<Null<String>> = [shape.objectFieldKind, shape.mapLiteralEntryKind];
		return partKinds.contains(node.kind)
			? node.children.foreach(c -> inertElement(c, plugin, shape))
			: inertCollection(node, plugin, shape);
	}

	/**
	 * The type annotation the declaration of the field `name` at `span` writes, read from `source`:
	 * `Absent` with no annotation, `Written(text)` with one, `Unreadable` when the name cannot be found in
	 * the declaration text.
	 */
	private static function fieldDeclaredType(source: String, span: Span, name: String): DeclaredType {
		final text: String = source.substring(span.from, span.to);
		final at: Int = SourceText.lastStandaloneIdentIndex(text, name);
		if (at < 0) return Unreadable;
		var rest: String = text.substring(at + name.length).trim();
		if (rest.endsWith(';')) rest = rest.substring(0, rest.length - 1).trim();
		if (rest == '') return Absent;
		if (!rest.startsWith(':')) return Unreadable;
		final type: String = rest.substring(1).trim();
		return type == '' ? Unreadable : Written(type);
	}

	/**
	 * Whether a field declared with `declared` holds a value whose `null` stand-in FAULTS on a member or
	 * index access: no annotation (the literal types it), an anonymous structure, `Dynamic`, or an
	 * UNQUALIFIED core array / map name (`RefShape.arrayTypeNames` / `mapAbstractTypeNames`). Anything
	 * else refuses — an abstract whose `@:from` turns the literal into a call, an abstract method that
	 * accepts a `null` receiver, a class of unknown behaviour — as does an unreadable annotation.
	 */
	private static function faultingFieldType(declared: DeclaredType, shape: RefShape): Bool {
		return switch declared {
			case Absent: true;
			case Written(text):
				final head: String = annotationHead(text);
				text.startsWith('{') || head == shape.rawDynamicTypeName || (shape.arrayTypeNames ?? []).contains(head)
					|| (shape.mapAbstractTypeNames ?? []).contains(head);
			case Unreadable: false;
		};
	}

	/**
	 * Whether code outside the project may name `member` of `container`: the member carries the public
	 * modifier, or its container is declared under a public-by-default annotation or modifier
	 * (`publicDefaultMetaNames`, `extern`). Fails closed — a grammar with no public modifier kind, or a
	 * member or container whose parent cannot be found in `tree`, reads as exposed.
	 */
	private static function fieldExposed(
		tree: QueryNode, member: QueryNode, container: QueryNode, plugin: GrammarPlugin, shape: RefShape
	): Bool {
		final publicKind: Null<String> = shape.publicModifierKind;
		final host: Null<QueryNode> = TreePath.parentOf(tree, member);
		final outer: Null<QueryNode> = TreePath.parentOf(tree, container);
		if (publicKind == null || host == null || outer == null) return true;
		final runKinds: Array<String> = CheckScan.modifierKinds(shape).concat(plugin.metaShape().metaKinds);
		if (MemberKinds.precedingModifiers(member, host, runKinds).exists(m -> m.kind == publicKind)) return true;
		final publicMetaNames: Array<String> = shape.publicDefaultMetaNames ?? [];
		final externKind: Null<String> = shape.externModifierKind;
		return MemberKinds.precedingModifiers(container, outer, runKinds)
			.exists(m -> m.kind == externKind || m.name != null && publicMetaNames.contains(m.name));
	}

	/**
	 * Whether any file of `scope` holds an early-observable occurrence of the field `name` declared at
	 * `fieldFrom` in `file` (`observableRead`). A scope file that mentions the name but does not parse, or
	 * an unparsed `#if` region spelling it, counts as one: either may hold any occurrence at all.
	 */
	private static function readObservableInScope(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, scope: Array<{ file: String, source: String }>,
		file: String, name: String, fieldFrom: Int
	): Bool {
		final shape: RefShape = plugin.refShape();
		final occurrenceKinds: Array<String> = [
			for (k in [
				shape.identKind,
				shape.fieldAccessKind,
				shape.nullSafeAccessKind,
				shape.forceFieldAccessKind,
				shape.stringInterpIdentKind
			])
				if (k != null) k
		];
		final faultingKinds: Array<String> = [
			for (k in [shape.fieldAccessKind, shape.indexAccessKind, shape.callKind]) if (k != null) k
		];
		final classLike: Array<String> = MemberKinds.classLikeContainerKinds(shape);
		final tryKinds: Array<String> = (shape.tryStatementKinds ?? []).concat(shape.tryExpressionKinds ?? []);
		for (entry in scope) if (RawSourceScan.mentionsWord(entry.source, name)) {
			final parsed: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (parsed == null) return true;
			final root: QueryNode = parsed;
			// An unparsed `#if` region projects no nodes, so the walk below cannot see a read inside one.
			if (CondRegionScan.opaqueCondRegionMentioning(root, entry.source, name, shape) != null) return true;
			final scan: EarlyReadScan = {
				name: name,
				fieldFile: file,
				fieldFrom: fieldFrom,
				file: entry.file,
				tree: root,
				writesCounted: files.exists(f -> f.file == entry.file),
				shape: shape,
				classLike: classLike,
				occurrenceKinds: occurrenceKinds,
				faultingKinds: faultingKinds,
				tryKinds: tryKinds,
				catchKind: shape.catchClauseKind
			};
			if (observableRead(root, null, 0, null, false, scan)) return true;
		}
		return false;
	}

	/** The outer name an annotation writes — the text before its type arguments, trimmed. */
	private static function annotationHead(text: String): String {
		final lt: Int = text.indexOf('<');
		return (lt < 0 ? text : text.substring(0, lt)).trim();
	}

	/**
	 * Whether the core name a WRITTEN annotation relies on (`faultingFieldType`) may name a user type in
	 * `file` instead, decided by the resolution index rather than by text. Shadowed when the file, or an
	 * ambient `import.hx` above it, imports a path whose last segment or alias is that name; when any
	 * wildcard import is in reach (which package it opens is not decided here, so it refuses); when the
	 * name resolves from `file` to a project declaration (the file's own, a same-package sibling's) or to
	 * any declaration outside the root package; or when a project file declares it in the root package,
	 * which every file sees unqualified. Refuses too when the index or the file's entry is missing or the
	 * ambient chain could not be bounded.
	 */
	private static function coreNameShadowed(
		host: SymbolIndexHost, file: String, declared: DeclaredType, scope: Array<{ file: String, source: String }>
	): Bool {
		final text: String = switch declared {
			case Written(written): written;
			case _: return false;
		};
		if (text.startsWith('{')) return false;
		final head: String = annotationHead(text);
		final index: Null<SymbolIndex> = host.resolutionIndex();
		if (index == null) return true;
		final found: Null<FileInfo> = index.fileInfo(file);
		if (found == null) return true;
		final info: FileInfo = found;
		if (!info.ambientImportsBounded) return true;
		final imports: Array<ImportInfo> = info.imports.concat([for (group in info.ambientImports) for (i in group.imports) i]);
		if (imports.exists(i -> i.kind == ImportKind.Wild || (i.alias ?? i.raw.substr(i.raw.lastIndexOf('.') + 1)) == head)) return true;
		final project: Array<String> = [for (entry in scope) entry.file];
		return index.resolveTypeRefsFrom(head, file).exists(d -> d.file.pkg != '' || project.contains(d.file.file))
			|| index.refs.resolvedDeclsNamed(head).exists(d -> d.file.pkg == '' && project.contains(d.file.file));
	}

}

/**
 * One accepted-or-rejectable constructor init: the field's `name` and declaration `span`, the
 * top-level statement it owns (`stmtFrom`, the chain walk's key), whether the field's cross-file
 * write count is one (`sole`, the legacy path) and whether the write is an assignment EXPRESSION
 * rather than a statement of its own (`embedded`).
 *
 * Order-safety is NOT a field here: `candidateFor` refuses a right-hand side that resolves
 * anything in-class, so every candidate is order-safe by construction.
 */
private typedef Candidate = {
	var name: String;
	var stmtFrom: Int;
	var span: Span;
	var sole: Bool;
	var embedded: Bool;
}

/**
 * `container`'s candidates split by acceptance path — `byStmt` keyed by the top-level statement each
 * owns, `embedded` owning none — plus whether every PRE-EXISTING declaration initializer sharing the
 * prologue resolves nothing in-class (`coMoversOrderSafe`). The candidates need no such record: they
 * are order-safe by construction.
 */
private typedef Candidates = {
	var byStmt: Map<Int, Candidate>;
	var embedded: Array<Candidate>;
	var coMoversOrderSafe: Bool;
}

/**
 * The early-init narrowings of one file's run, as `candidateFor` asks them: whether the sole write of
 * the field `member` of `container`, right-hand side `rhs`, may be hoisted across an explicit
 * `super(...)`. `FieldInitAtDeclaration.crossingAdmitted`, bound to the run's files and plugin
 * and to the candidate's file, source and parsed tree.
 */
private typedef EarlyInitProof = (member:QueryNode, container:QueryNode, rhs:QueryNode) -> Bool;

/**
 * The invariants of one early-read scan over one scope file: the field (`name`, declared at
 * `fieldFrom` in `fieldFile`), the file being walked (`file`, whose parsed `tree` binding resolution
 * needs, and whether it is a REPORT file whose writes the write index already counted —
 * `writesCounted`), and the grammar seams the walk reads.
 */
private typedef EarlyReadScan = {
	var name: String;
	var fieldFile: String;
	var fieldFrom: Int;
	var file: String;
	var tree: QueryNode;
	var writesCounted: Bool;
	var shape: RefShape;
	var classLike: Array<String>;
	var occurrenceKinds: Array<String>;
	var faultingKinds: Array<String>;
	var tryKinds: Array<String>;
	var catchKind: Null<String>;
}

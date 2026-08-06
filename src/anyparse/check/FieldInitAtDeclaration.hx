package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.FieldWriteIndex;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags an INSTANCE field (`var` or `final`) that has NO declaration initializer but
 * whose write is one unconditional top-level constructor statement
 * `x = expr;` / `this.x = expr;` whose right-hand side is context-independent
 * (references no constructor parameters, no `this`, no other instance members, no
 * constructor locals — only literals, static / global references, and constructions
 * such as `new Shape()`). `Severity.Info`, with an autofix that MOVES `= expr` onto
 * the field declaration and deletes the constructor statement — e.g.
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
 * feature flag, a `throw`, a branch — while a declaration initializer ALWAYS runs. So
 * a candidate additionally demands `RefactorSupport.ctorPrefixUnconditional`: every
 * top-level statement before its init is straight-line (an expression statement or a
 * local declaration; `super(…)` is one of those) and no control exit starts before it
 * anywhere in the body subtree. The live regression that bought this gate hoisted an
 * asset load out from behind `if (!USE_CACHE) return;`, making it unconditional; the
 * moved code still type-checked and still parsed, so nothing downstream could catch
 * it. The gate sits on the CANDIDATE, not on either acceptance path below, so neither
 * path can miss it.
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
 * read-before-init gate and the reachable-prefix gate apply to both paths.
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
 *   from before the chain existed. What it can no longer do is hop a BRANCH or an
 *   early exit — `ctorPrefixUnconditional` refuses a prefix that is not straight-line
 *   on BOTH paths. The CHAIN path is stricter still: any non-candidate statement
 *   breaks the chain, where the legacy path only asks that the prefix be reached.
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
 * qualifies, so the init timing stays unambiguous. A `#if` member REGION anywhere in
 * the container refuses every chained candidate: the projection keeps its interior as
 * trivia, so an initializer inside it cannot be inspected. A field whose write count
 * differs from one qualifies only through the chain; an UNRESOLVED write to the field
 * NAME disqualifies it on either path.
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
		final classLike: Array<String> = RefactorSupport.classLikeContainerKinds(shape);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = try plugin.parseFile(entry.source) catch (_: Exception) null;
			if (tree != null) walk(tree, entry.file, entry.source, shape, classLike, writeIndex, violations);
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
			if (loc == null) continue;
			final rhsSpan: Null<Span> = loc.rhs.span;
			final fieldSpan: Null<Span> = loc.field.span;
			final stmtSpan: Null<Span> = loc.stmt.span;
			if (rhsSpan == null || fieldSpan == null || stmtSpan == null) continue;
			if (!prefixMovesTogether(loc.container, stmtSpan.from, moving, source, shape)) {
				final key: String = '${v.file}#${loc.field.name}';
				if (!skipsReported.contains(key)) {
					skipsReported.push(key);
					stderr(
						'apq fix: field-init-at-declaration: \'${loc.field.name}\' skipped — a prefix candidate is not in the fix set\n'
					);
				}
				continue;
			}
			final insertPos: Int = RefactorSupport.fieldDeclInitInsertPos(source, fieldSpan);
			edits.push({ span: new Span(insertPos, insertPos), text: ' = ${source.substring(rhsSpan.from, rhsSpan.to)}' });
			edits.push({ span: RefactorSupport.lineExtendedSpan(source, stmtSpan), text: '' });
		}
		return edits;
	}

	/** Walk `node`, considering every class-like container found. */
	private static function walk(
		node: QueryNode, file: String, source: String, shape: RefShape, classLike: Array<String>, writeIndex: FieldWriteIndex,
		out: Array<Violation>
	): Void {
		if (classLike.contains(node.kind)) considerContainer(node, file, source, shape, writeIndex, out);
		for (child in node.children) walk(child, file, source, shape, classLike, writeIndex, out);
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
		container: QueryNode, file: String, source: String, shape: RefShape, writeIndex: FieldWriteIndex, out: Array<Violation>
	): Void {
		final owner: Null<String> = container.name;
		if (owner == null) return;
		final ctor: Null<QueryNode> = RefactorSupport.soleConstructor(container, shape);
		if (ctor == null) return;
		final statics: Array<Int> = RefactorSupport.staticMemberFroms(container, shape);
		final byStmt: Map<Int, Candidate> = [];
		var coMoversOrderSafe: Bool = true;
		for (member in container.children) {
			final cand: Null<Candidate> = candidateFor(member, container, ctor, owner, source, statics, shape, writeIndex);
			if (cand == null) {
				if (coMoverOrderUnsafe(member, container, statics, source, shape)) coMoversOrderSafe = false;
				continue;
			}
			byStmt[cand.stmtFrom] = cand;
		}
		for (cand in byStmt) if (cand.sole && !cand.orderSafe) coMoversOrderSafe = false;
		var chainOk: Bool = true;
		for (stmt in ctorStatements(ctor, shape)) {
			final stmtSpan: Null<Span> = stmt.span;
			final cand: Null<Candidate> = stmtSpan == null ? null : byStmt[stmtSpan.from];
			if (cand == null) {
				chainOk = false;
				continue;
			}
			if (!cand.sole && !(chainOk && coMoversOrderSafe && cand.orderSafe)) {
				chainOk = false;
				continue;
			}
			out.push({
				file: file,
				span: cand.span,
				rule: 'field-init-at-declaration',
				severity: Severity.Info,
				message: 'field \'${cand.name}\' is initialised with a constant in the constructor; move it to the declaration'
			});
		}
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
	): Null<{ name: String, span: Span }> {
		final stmtKind: Null<String> = shape.exprStatementKind;
		final assignKind: Null<String> = shape.assignKind;
		if (stmtKind == null || assignKind == null || stmt.kind != stmtKind || stmt.children.length < 1) return null;
		final assign: QueryNode = stmt.children[0];
		if (assign.kind != assignKind || assign.children.length < 2) return null;
		final target: QueryNode = assign.children[0];
		for (member in container.children) {
			final mv: Null<{ name: String, span: Span }> = movableField(member, statics, source, shape);
			if (mv != null && denotesMember(target, mv.span.from, mv.name, container, shape)) return mv;
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
		container: QueryNode, boundary: Int, moving: Array<Int>, source: String, shape: RefShape
	): Bool {
		final ctor: Null<QueryNode> = RefactorSupport.soleConstructor(container, shape);
		if (ctor == null) return false;
		final statics: Array<Int> = RefactorSupport.staticMemberFroms(container, shape);
		for (stmt in ctorStatements(ctor, shape)) {
			final span: Null<Span> = stmt.span;
			if (span == null || span.from >= boundary) continue;
			final mv: Null<{ name: String, span: Span }> = assignedMovableField(stmt, container, statics, source, shape);
			if (mv != null && !moving.contains(mv.span.from)) return false;
		}
		return true;
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
		node: QueryNode, container: QueryNode, statics: Array<Int>, shape: RefShape, allowStatics: Bool
	): Bool {
		final identKind: String = shape.identKind;
		final selfText: Null<String> = shape.selfReferenceText;
		// `$p` inside a single-quoted string projects as the interp `Ident` kind, not
		// `IdentExpr` - it is a reference all the same (`${p}` blocks carry a regular
		// IdentExpr child and were already reached by the child walk).
		final isInterpIdent: Bool = shape.stringInterpIdentKind != null && node.kind == shape.stringInterpIdentKind;
		if (node.kind == identKind || isInterpIdent) {
			final name: Null<String> = node.name;
			final span: Null<Span> = node.span;
			if (name == null || span == null) return false;
			if (selfText != null && name == selfText) return false;
			final bf: Null<Int> = TypeResolver.resolveBindingFrom(name, span, container, shape);
			// A bare `$name` interp ident does not register as a binding read, so an
			// unresolved one is NOT provably global - in practice it is almost always
			// a local/param; fail closed. A regular unresolved IdentExpr stays the
			// provably-global case (imports/statics) - UNLESS the container has a
			// supertype clause: an INHERITED member is invisible to the single-file
			// resolver and indistinguishable from a global, so under `extends` /
			// `implements` an unresolved lowercase ident fails closed too (type
			// refs like `Colors.WHITE` keep their uppercase root and stay movable).
			if (isInterpIdent) return allowStatics && bf != null && statics.contains(bf);
			if (bf != null) return allowStatics && statics.contains(bf);
			if (!hasSupertype(container, shape)) return true;
			final c0: Int = StringTools.fastCodeAt(name, 0);
			return c0 >= 'A'.code && c0 <= 'Z'.code;
		}
		for (child in node.children) if (!contextFreeRhs(child, container, statics, shape, allowStatics)) return false;
		return true;
	}

	/**
	 * Whether the field is referenced anywhere in the constructor BEFORE its
	 * initializing statement. Any such reference is a READ: a second TOP-LEVEL
	 * constructor write to the same field would have made `soleConstructorFieldInit`
	 * return null (it demands a single match), and a NESTED write sits under a branch
	 * or loop, a statement shape the chain refuses outright. Moving the init ahead of
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
		member: QueryNode, container: QueryNode, statics: Array<Int>, source: String, shape: RefShape
	): Bool {
		if (RefactorSupport.isConditionalKind(member.kind)) return true;
		final fields: Array<String> = shape.fieldDeclKinds ?? [];
		final span: Null<Span> = member.span;
		return span != null && fields.contains(member.kind) && !statics.contains(span.from) && member.children.length >= 1
			&& !contextFreeRhs(member.children[0], container, statics, shape, false);
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
		writeIndex: FieldWriteIndex
	): Null<Candidate> {
		final mv: Null<{ name: String, span: Span }> = movableField(member, statics, source, shape);
		if (mv == null) return null;
		final init: Null<{ stmt: QueryNode, rhs: QueryNode, target: Span }> = RefactorSupport.soleConstructorFieldInit(
			container, ctor, member, shape
		);
		if (init == null) return null;
		final stmtSpan: Null<Span> = init.stmt.span;
		if (stmtSpan == null || writeIndex.hasUnresolvedWrite(mv.name)) return null;
		// Gating the CANDIDATE rather than one of the two acceptance paths is what makes both
		// inherit it: the chain path already demanded an unbroken run of accepted inits, so
		// this is a no-op there, and the sole-write path — which looks at no prefix at all —
		// is the one that needed it.
		if (!RefactorSupport.ctorPrefixUnconditional(ctor, stmtSpan.from, shape)) return null;
		final unsafeRead: Bool = readBeforeInit(ctor, mv.span.from, mv.name, stmtSpan.from, container, shape);
		return !contextFreeRhs(init.rhs, container, statics, shape, true) || unsafeRead ? null : {
			name: mv.name,
			stmtFrom: stmtSpan.from,
			span: mv.span,
			orderSafe: contextFreeRhs(init.rhs, container, statics, shape, false),
			sole: writeIndex.writeCount(owner, mv.name) == 1
		};
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
}

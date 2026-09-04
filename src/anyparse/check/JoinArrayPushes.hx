package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.PurityScan.PurityCtx;
import anyparse.query.CanonicalEdit;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.CtorFieldFold;
import anyparse.query.CtorFieldWrite;
import anyparse.query.FieldWriteIndex;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberKinds;
import anyparse.query.NominalTypes;
import anyparse.query.OccurrenceScan;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * Flags an EMPTY-ARRAY binding followed by a run of `a.push(<expr>);` statements — an array
 * literal written the long way — and folds the pushed expressions back into the `[]`.
 * `Severity.Info` (a readability cleanup, never a correctness finding), with an autofix.
 * Grammar-agnostic over `RefShape`.
 *
 * Nothing else in the registry covers this shape. `prefer-comprehension` needs a `for` loop as
 * the push source; `prefer-array-literal` only rewrites `new Array()` into `[]`;
 * `field-init-at-declaration` moves a constructor ASSIGNMENT onto a field declaration, and only
 * one whose declaration carries NO initializer.
 *
 * ## Two acceptance paths
 *
 * ### Path A — a fresh local declaration, nothing moves
 *
 * A local `var` / `final` DECLARATION whose initializer is the grammar's array-literal kind with
 * NO elements, IMMEDIATELY followed by a maximal run of adjacent `a.push(e);` expression
 * statements in the SAME statement list — `final a:Array<Int> = []; a.push(x); a.push(y);`
 * becomes `final a:Array<Int> = [x, y];`.
 *
 * Nothing is reordered: the elements land in the literal in exactly the order the pushes stood
 * in, strict adjacency means no foreign statement sat between them, and the declaration BINDS the
 * name, so nothing before it could read what the pushes fill. Those three together are why Path A
 * needs no purity proof — `a.push(new T()); a.push(f());` folds here, because `new T()` and `f()`
 * still run in that order, in that place, and neither can observe `a`.
 *
 * An ASSIGNMENT to an existing name (`_a = []; _a.push(e);`) is deliberately NOT accepted, and the
 * distinction is the whole reason the paragraph above is scoped to a DECLARATION. The assignment
 * is an evaluation point that RUNS, and folding moves every element to before it: an element
 * reading the assigned name INDIRECTLY (`_a.push(count())`, where `count()` returns `_a.length`)
 * would see the PRE-assignment value, and a property target would run its setter once with the
 * filled literal instead of once with `[]` and once filled. The self-reference gate sees only a
 * DIRECT mention of the name and catches neither.
 *
 * ### Path B — field declaration, across the constructor prologue
 *
 * An INSTANCE field whose declaration initializer is the empty array literal, plus a maximal run
 * of `f.push(e)` / `this.f.push(e)` statements at the TOP LEVEL of the constructor body — direct
 * children of the body's statement list, so a push nested in an `if`, a loop or a `#if` region is
 * never part of a run (a conditional region projects as ONE statement of its own kind, which
 * breaks the run at its first element).
 *
 * Here the elements really do move: a declaration initializer runs BEFORE the constructor body,
 * so a folded element crosses the whole constructor prologue, the explicit `super(…)` included.
 * Path A's gates are therefore not enough, and Path B adds the ones below.
 *
 * ## Path B soundness gates
 *
 * - **Every element is a CONTEXT-FREE CONSTANT.** Two separate proofs, both required, because
 *   they answer different questions:
 *   - PURITY (`PurityScan.isPure`) — the element's own evaluation has no observable effect, so
 *     performing it earlier changes nothing about the element itself. A `new T()` or any call
 *     other than a provably-pure stdlib static is refused here (it still folds on Path A). A
 *     COLLECTION LITERAL — the array / object literal and its fields — is admitted by this rule
 *     rather than by `PurityScan`, exactly as `unnecessary-switch` admits it: the safe direction
 *     differs per caller, and here each element is still evaluated exactly once, merely earlier,
 *     so the allocation is neither dropped nor shared. Without that arm the motivating site, whose
 *     elements are object literals, would not fold at all. Whether anything can OBSERVE the array
 *     filling earlier is a separate question, settled by the prologue and virtual-read gates
 *     below, not by this one.
 *   - CONTEXT-FREEDOM (`RefactorSupport.contextFreeRhs`, shared with
 *     `field-init-at-declaration`) — the element text must be LEGAL where it is moving. Haxe
 *     rejects `this` and a sibling-instance read in a declaration initializer, and a constructor
 *     parameter or local does not exist yet. `mayBeInherited` is answered `true`
 *     unconditionally: this rule holds no import evidence, and refusing an unresolved lowercase
 *     name under `extends` is the closed direction.
 * - **The prologue is reached** (`RefactorSupport.ctorPrefixUnconditional`). A run sitting behind
 *   an early `return` / `throw`, or after a loop that need not terminate, is CONDITIONAL code; a
 *   declaration initializer always runs, so folding it there would make it unconditional.
 * - **The prologue RUNS NOTHING.** No top-level constructor statement before the run may hold a
 *   call or a `new` anywhere in its subtree. This is the hazard purity cannot reach: purity proves
 *   the ELEMENTS observe nothing, and says nothing about what the PROLOGUE observes — a plain
 *   `log();` before the run, whose method reads the field's `length`, sees an empty array today
 *   and a filled one after the fold. The `super(…)` statement is the one exemption, because
 *   crossing it is what the virtual-read gate below governs.
 * - **No earlier observation of the field.** The field name must not occur anywhere in the
 *   constructor before the run — a textual scan, so a `$f` interpolation and a same-named
 *   parameter or local both refuse. That single gate also settles shadowing: a binding that could
 *   capture the push receiver has to be declared or bound before the run, and its own name token
 *   trips the scan.
 * - **No virtual read from a base constructor.** When the constructor calls up, the base
 *   constructor may reach back into this class through a virtual call, and that is the one hazard
 *   purity does not cover: it would observe a populated array where it used to see an empty one.
 *   So under `super(…)` no `override` member of this class may mention the field. This is
 *   deliberately NOT `field-init-at-declaration`'s blanket "refuse every constructor that calls
 *   up": that rule moves an arbitrary right-hand side, so foreign code could run early and its
 *   veto is the honest one — here the purity and prologue gates have already excluded foreign
 *   code, and the blanket veto would kill the motivating site (which calls `super()`) for a hazard
 *   that cannot arise.
 * - **No other write to the field.** `FieldWriteIndex` must report ZERO writes to
 *   `(owner, field)` — the declaration initializer is the field's only assignment, and any
 *   `f = …` elsewhere could replace the array the pushes were meant to fill — and no UNRESOLVED
 *   write to the field NAME anywhere in the scope, the same soundness bail
 *   `field-init-at-declaration` takes.
 * - **A single declaration.** A name the container declares more than once (only reachable across
 *   mutually exclusive `#if` branches) is refused: the run would fold into one branch's literal
 *   while the other branch's field lost its pushes.
 *
 * Three residuals of the Path B gates, NAMED rather than gated. A prologue statement whose
 * PROPERTY ACCESSOR touches the field — an assignment whose l-value is a property whose SETTER
 * reads it, or a read of a property whose GETTER does — holds no call node, because the call is
 * the accessor the compiler inserts, so the prologue gate cannot see it. The `super(…)` exemption
 * covers the whole STATEMENT, its ARGUMENTS included, so a `super(f())` whose `f` reads the field
 * is not seen either. And the virtual-read scan is per-member and TEXTUAL: an implementation of an
 * `abstract` base method carries no `override` keyword in Haxe and is invisible to it, as is an
 * `override` that mentions the field only through a private helper it delegates to.
 *
 * ## Gates both paths share
 *
 * - **The binding is provably an ARRAY.** When it carries an explicit type annotation, that
 *   annotation's OUTER NOMINAL name — `NominalTypes.outerNominalOf`, which drops the package
 *   qualifier and the type arguments, so `pkg.Array<Int>` reads as `Array` — must be a
 *   `RefShape.arrayTypeNames` entry, and that seam is documented as holding SIMPLE names for
 *   exactly this reason. A head the annotation reader cannot attribute to the declared name
 *   (`RefactorSupport.DeclaredType.Unreadable`, e.g. `final stack:pkg.stack = []`) refuses too:
 *   only a POSITIVE `Absent` is a proof that the initializer types the
 *   binding, and an unannotated `= []` is that proof. The gate exists because a user `abstract`
 *   over `Array<T>` may declare a `push` of its own with entirely different semantics — one that
 *   PREPENDS turns two pushes into the reversed literal — and nothing else here would notice.
 * - **Strict adjacency.** The pushes of a run are consecutive siblings, and the run is maximal — it
 *   ends at the first statement that is not a push on the same name. On Path A the DECLARATION is
 *   the sibling immediately before the run; on Path B the binding is a field, so adjacency
 *   constrains the run alone and the field is tied to it by the receiver instead.
 * - **No comment in the folded region.** The pushes are deleted and their arguments are spliced
 *   into one literal, so a `//` anywhere in that region would either be lost or comment out the
 *   rest of the line. Both paths scan to the END OF THE LINE the last push sits on rather
 *   than to the statement end, so a trailing `// note` on the last push refuses instead of
 *   silently re-attaching to the surviving declaration. Path A scans ONE region, the declaration's
 *   start through that line end, since the declaration and the run are contiguous; Path B scans
 *   TWO disjoint ones, the field declaration's own span and the run's start through that line end,
 *   because everything between them stays where it is. Refusing is the
 *   conservative direction (and the scan is string-blind, so a `'//'` inside an element refuses
 *   too).
 * - **No self-reference.** `a` must not appear in any element — `a.push(a.length)` reads the array
 *   being built — whether as a plain identifier or as a `$a` string interpolation, mirroring
 *   `prefer-comprehension`'s gate. Only the push receiver is the bound name, and it is not scanned.
 * - **Read afterwards.** The name must be referenced after the run, within the enclosing block
 *   (Path A) or the container (Path B); otherwise the array feeds no one and the finding belongs
 *   to `unused-local` / a dead-member rule instead. On Path B the field's OWN declaration is
 *   excluded from that scan — a field declared BELOW the constructor lies in the range and would
 *   otherwise satisfy the gate with nothing but itself.
 *
 * ## Autofix
 *
 * One edit replaces the `[]` span with `[e1, e2, …]`, each element sliced VERBATIM from its push
 * argument's span (as `prefer-comprehension`'s fixer slices its produced element), plus one
 * deletion per push statement spanning `[end of the previous line, statement end]`. The elements
 * are joined with `, ` and no line breaks are introduced, so the literal is one line unless an
 * ARGUMENT was itself written across several — its text carries those newlines along. The deletion
 * never extends FORWARD, which is what leaves a statement sharing the push's line standing — and is also why the comment gate has
 * to scan to that line's end. Either way the layout is not this rule's to decide: `lint --fix`
 * canonicalises every file it writes, so the project's own `hxformat.json` array-wrapping policy
 * has the last word on whether a sixteen-element literal stays inline or goes one element per
 * line.
 *
 * ## Grammar-agnostic
 *
 * `readSeams` names the REQUIRED seams — the call, field-access, expression-statement and
 * array-literal kinds, the minimum needed to see a `<name>.push(e);` and an `[]` at all — and
 * returns null when any is unset, which makes the whole check a no-op. Most other seams are
 * OPTIONAL and cost only REACH: without `blockKinds` Path A cannot find a statement list, without
 * `blockBodyKind` / `fieldDeclKinds` / a class-like container kind Path B cannot find a
 * constructor, and without `arrayTypeNames` only an UNANNOTATED binding can be proven an array.
 *
 * Five seams fail CLOSED instead, because an unset one would remove a PROOF rather than a shape.
 *
 * TWO of them disarm the WHOLE rule, and are checked in `readSeams` beside the required ones:
 * `stringInterpIdentKind` unset stops `referencesName` seeing `a.push('$a')`, and the fix would
 * then emit a literal that does not compile; `opaqueKinds` unset stops reification subtrees being
 * skipped, and `referencesName`'s fail-closed answer for them disappears with it. The consequence
 * a plugin author must know is blunt: a grammar for a language with NEITHER macros NOR string
 * interpolation legitimately declares neither seam, and gets this rule as a SILENT TOTAL NO-OP —
 * indistinguishable from having forgotten to declare them. That is the deliberate choice, and the
 * reason is that both seams carry the proof `referencesName` owes rather than a shape it looks
 * for: a narrower gate would have to decide, per element, whether the grammar can even express an
 * interpolated read, and answering that needs a string-literal seam this rule does not read.
 * Declare the seams — an empty `opaqueKinds` is not the way to say "this language has no
 * reification".
 *
 * ONE disarms Path B: `newExprKind` unset makes the prologue gate refuse rather than admit an
 * unrecognisable `new`. The remaining two only ever TIGHTEN Path B and never disarm it, since
 * both feed gates that a constructor with no `super(…)` never reaches: `superReferenceText` unset
 * makes `constructorCallsUp` answer true AND un-exempts the `super(…)` statement from the
 * prologue gate, and `overrideModifierKind` unset makes `overrideMemberReads` answer true, which
 * is consumed only under `constructorCallsUp`.
 */
@:nullSafety(Strict)
final class JoinArrayPushes implements Check {

	/** The rule id, also the `rule` field of every violation it reports. */
	private static inline final RULE_ID: String = 'join-array-pushes';

	/** The appending method whose argument becomes one literal element. */
	private static inline final PUSH_METHOD: String = 'push';

	/** A `push` call has exactly [callee, single-argument] children. */
	private static inline final PUSH_CALL_CHILD_COUNT: Int = 2;

	/** A field whose array is filled only by the folded run carries no assignment at all. */
	private static inline final NO_WRITES: Int = 0;

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'an empty-array binding followed by push statements that fold into the array literal';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final resolved: Seams = seams;
		final symbols: () -> Null<SymbolIndex> = RefactorSupport.lazySymbolIndex(files, plugin);
		final writes: () -> FieldWriteIndex = lazyWriteIndex(files, plugin);
		return [
			for (entry in files) for (m in collectMatches(plugin, entry.source, resolved, symbols, writes))
				{
					file: entry.file,
					span: m.span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: 'the push statements after this empty array can be folded into the literal'
				}
		];
	}

	/**
	 * Fold each flagged binding: replace its `[]` with the assembled literal and delete the push
	 * lines. The candidate set is re-derived from the re-parsed source — with the caller's
	 * report-scoped index when it supplied one, else one built over this file alone — so a
	 * reported span that no longer names a foldable binding produces no edit. The single-file
	 * index is the narrower one, which can only ADMIT more candidates than `run` saw, never fewer:
	 * the extra ones match no violation and yield nothing.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null || violations.length == 0) return [];
		final files: Array<{ file: String, source: String }> = [{ file: violations[0].file, source: source }];
		final symbols: () -> Null<SymbolIndex> = RefactorSupport.lazySymbolIndex(files, plugin, index);
		final writes: () -> FieldWriteIndex = lazyWriteIndex(files, plugin);
		final byKey: Map<String, Match> = [];
		for (m in collectMatches(plugin, source, seams, symbols, writes)) byKey['${m.span.from}:${m.span.to}'] = m;
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final m: Null<Match> = byKey['${span.from}:${span.to}'];
			if (m != null) for (edit in m.edits) edits.push(edit);
		}
		return CanonicalEdit.dropContainedEdits(edits);
	}

	/**
	 * The span of an initializer that IS the empty array literal — the grammar's array-literal kind
	 * with no elements — or null. Asked of the tree rather than of the source text: the projection
	 * already states what the initializer is, and `new Array()` (a different kind) is
	 * `prefer-array-literal`'s to rewrite first.
	 */
	private static inline function emptyArraySpan(init: QueryNode, s: Seams): Null<Span> {
		return init.kind == s.arrayLiteralKind && init.children.length == 0 ? init.span : null;
	}

	/**
	 * Bundle the required + optional `RefShape` kinds, or null when a required one is unset (the
	 * check is then a no-op). See the class doc for which unset seam costs what.
	 */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final callKind: Null<String> = shape.callKind;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		final arrayLiteralKind: Null<String> = shape.arrayLiteralKind;
		if (callKind == null || fieldAccessKind == null || exprStmtKind == null || arrayLiteralKind == null) return null;
		// Both of these fail CLOSED: they do not describe a SHAPE the rule can miss, they carry a
		// PROOF it would silently lose. Without the interpolation identifier kind `referencesName`
		// stops seeing `a.push('$a')` and the fix emits a literal that does not compile; without the
		// reification kinds a `macro` subtree is walked as ordinary code and `referencesName`'s
		// fail-closed answer for it disappears.
		final interpIdentKind: Null<String> = shape.stringInterpIdentKind;
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		if (interpIdentKind == null || opaqueKinds.length == 0) return null;
		final flow: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		return {
			shape: shape,
			identKind: shape.identKind,
			callKind: callKind,
			fieldAccessKind: fieldAccessKind,
			exprStmtKind: exprStmtKind,
			arrayLiteralKind: arrayLiteralKind,
			blockKinds: flow == null ? [] : flow.blockKinds(),
			localDeclKinds: shape.localDeclKinds ?? [],
			continuationKinds: shape.localDeclContinuationKinds ?? [],
			blockBodyKind: shape.blockBodyKind,
			fieldDeclKinds: shape.fieldDeclKinds ?? [],
			memberDeclKinds: shape.memberDeclKinds ?? [],
			classLikeKinds: MemberKinds.classLikeContainerKinds(shape),
			opaqueKinds: opaqueKinds,
			interpIdentKind: interpIdentKind,
			newExprKind: shape.newExprKind,
			arrayTypeNames: shape.arrayTypeNames ?? [],
			selfText: shape.selfReferenceText,
			superText: shape.superReferenceText,
			overrideKind: shape.overrideModifierKind,
			collectionKinds: [
				for (k in [shape.arrayLiteralKind, shape.objectLiteralKind, shape.objectFieldKind]) if (k != null) k
			]
		};
	}

	/**
	 * Every foldable binding in `source`, each with its replacement span and the edits that fold
	 * it. The purity context is built at most ONCE per file and only when a Path B run reaches
	 * that gate — most files hold none, and building it forces the symbol index.
	 */
	private static function collectMatches(
		plugin: GrammarPlugin, source: String, seams: Seams, symbols: () -> Null<SymbolIndex>, writes: () -> FieldWriteIndex
	): Array<Match> {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final root: QueryNode = tree;
		var purity: Null<PurityCtx> = null;
		var built: Bool = false;
		final out: Array<Match> = [];
		walk(root, {
			source: source,
			seams: seams,
			writes: writes,
			purity: () -> {
				if (!built) {
					built = true;
					final index: Null<SymbolIndex> = symbols();
					purity = index == null ? null : PurityScan.contextOf(plugin, source, root, index);
				}
				return purity;
			}
		}, out);
		return out;
	}

	/**
	 * Descend `node`, scanning every statement list for Path A and every class-like container for
	 * Path B. A reification subtree (`opaqueKinds`) is skipped wholesale — code written there is
	 * the AST the surrounding program BUILDS, not code that runs.
	 */
	private static function walk(node: QueryNode, ctx: Ctx, out: Array<Match>): Void {
		final s: Seams = ctx.seams;
		if (s.opaqueKinds.contains(node.kind)) return;
		if (s.blockKinds.contains(node.kind)) scanStatements(node, ctx, out);
		if (s.classLikeKinds.contains(node.kind)) scanConstructor(node, ctx, out);
		for (child in node.children) walk(child, ctx, out);
	}

	/** Path A: every empty-array local declaration in `block`'s statement list that a push run follows. */
	private static function scanStatements(block: QueryNode, ctx: Ctx, out: Array<Match>): Void {
		final blockSpan: Null<Span> = block.span;
		if (blockSpan == null) return;
		final scope: Span = blockSpan;
		final kids: Array<QueryNode> = block.children;
		for (i in 0...kids.length) {
			final decl: Null<LocalDecl> = emptyArrayLocal(kids[i], ctx);
			if (decl == null) continue;
			final run: Array<Push> = localPushRun(kids, i + 1, decl.name, ctx);
			if (run.length == 0) continue;
			final m: Null<Match> = localMatch(decl, run, scope, ctx);
			if (m != null) out.push(m);
		}
	}

	/**
	 * `stmt` as an EMPTY-ARRAY LOCAL DECLARATION — a single-declarator `var` / `final` whose
	 * initializer is the empty array literal and whose annotation, if it wrote one, names an
	 * array — or null. A multi-variable declaration (`final a = [], b = 1;`) projects its
	 * continuation as a second child and is refused twice over: by the child count and by the
	 * continuation KIND, cross-grammar defence for a grammar projecting it as a sibling.
	 *
	 * An ASSIGNMENT to an existing name (`_a = []; _a.push(e);`) is deliberately NOT a binding.
	 * The assignment is an EVALUATION POINT, and folding moves every element to before it: an
	 * element that reads the assigned name INDIRECTLY (`_a.push(count())`, where `count()` reads
	 * `_a.length`) would then see the PRE-assignment value, and a property target would run its
	 * setter once with the filled literal instead of once with `[]` and once filled. The
	 * self-reference gate sees only a DIRECT mention of the name, so it catches neither. Only a
	 * FRESH DECLARATION — which nothing before it can name — is order-safe with no purity proof.
	 */
	private static function emptyArrayLocal(stmt: QueryNode, ctx: Ctx): Null<LocalDecl> {
		final s: Seams = ctx.seams;
		final span: Null<Span> = stmt.span;
		final name: Null<String> = stmt.name;
		if (span == null || name == null || !s.localDeclKinds.contains(stmt.kind)) return null;
		if (s.continuationKinds.contains(stmt.kind) || stmt.children.length != 1) return null;
		final literal: Null<Span> = emptyArraySpan(stmt.children[0], s);
		return literal == null || !annotationNamesArray(span, literal, name, ctx) ? null : {
			name: name,
			span: span,
			literal: literal
		};
	}

	/**
	 * Whether the binding's own type annotation — if it wrote one — names an ARRAY. A user
	 * `abstract` over `Array<T>` may declare a `push` of its own with different semantics
	 * (`this.unshift(v)` PREPENDS), so a `Stack<Int>` filled by two pushes is not the literal of
	 * those two elements in that order. An UNANNOTATED `= []` infers the array type from the
	 * literal and needs no proof; an annotated one must name a `RefShape.arrayTypeNames` entry, so
	 * an unset seam refuses every annotated binding — REACH, never soundness. A wrapper spelling
	 * (`Null<Array<Int>>`) names the wrapper and is refused too, the conservative direction.
	 */
	private static function annotationNamesArray(declSpan: Span, literal: Span, name: String, ctx: Ctx): Bool {
		return switch CtorFieldFold.declaredType(ctx.source, declSpan, literal, name) {
			case Absent: true;
			case Written(text):
				final root: Null<String> = NominalTypes.outerNominalOf(text);
				root != null && ctx.seams.arrayTypeNames.contains(root);
			case Unreadable: false;
		};
	}

	/** The maximal run of adjacent `<name>.push(e);` siblings starting at `start`, unqualified receivers only. */
	private static function localPushRun(kids: Array<QueryNode>, start: Int, name: String, ctx: Ctx): Array<Push> {
		final run: Array<Push> = [];
		for (i in start ... kids.length) {
			final push: Null<Push> = pushStatement(kids[i], ctx);
			if (push == null || push.name != name || push.qualified) break;
			run.push(push);
		}
		return run;
	}

	/**
	 * `stmt` as a `<name>.push(e);` / `this.<name>.push(e);` expression statement — the receiver
	 * name, the argument node and the spans the fix needs — or null when it is not exactly that.
	 * Shape only, with no gate of its own, so both paths ask it.
	 */
	private static function pushStatement(stmt: QueryNode, ctx: Ctx): Null<Push> {
		final s: Seams = ctx.seams;
		final stmtSpan: Null<Span> = stmt.span;
		if (stmtSpan == null || stmt.kind != s.exprStmtKind || stmt.children.length != 1) return null;
		final call: QueryNode = stmt.children[0];
		if (call.kind != s.callKind || call.children.length != PUSH_CALL_CHILD_COUNT) return null;
		final callee: QueryNode = call.children[0];
		if (callee.kind != s.fieldAccessKind || callee.name != PUSH_METHOD || callee.children.length != 1) return null;
		final arg: QueryNode = call.children[1];
		final argSpan: Null<Span> = arg.span;
		final receiver: QueryNode = callee.children[0];
		final receiverSpan: Null<Span> = receiver.span;
		final name: Null<String> = receiver.name;
		if (argSpan == null || receiverSpan == null || name == null) return null;
		final self: Null<String> = s.selfText;
		final qualified: Bool = receiver.kind == s.fieldAccessKind && self != null && receiver.children.length == 1
			&& receiver.children[0].kind == s.identKind && receiver.children[0].name == self;
		return receiver.kind != s.identKind && !qualified ? null : {
			name: name,
			stmt: stmtSpan,
			arg: arg,
			argSpan: argSpan,
			receiver: receiverSpan,
			qualified: qualified
		};
	}

	/**
	 * Path A's gates on a declaration-plus-run pair, and the fold when they all hold. Nothing moves
	 * across anything here — the elements land in the literal in the order the pushes stood in, and
	 * a FRESH declaration is a name nothing before it could read — so the element expressions need
	 * no purity proof; only the comment, self-reference and read-afterwards gates apply.
	 */
	private static function localMatch(decl: LocalDecl, run: Array<Push>, scope: Span, ctx: Ctx): Null<Match> {
		final source: String = ctx.source;
		final end: Int = run[run.length - 1].stmt.to;
		if (CheckScan.hasCommentMarker(source, decl.span.from, endOfLine(source, end))) return null;
		for (push in run) if (referencesName(push.arg, decl.name, ctx.seams)) return null;
		return OccurrenceScan.referencedInRange(source, decl.name, end, scope.to, []) ? {
			span: decl.span,
			edits: foldEdits(decl.literal, run, ctx)
		} : null;
	}

	/**
	 * Path B: every maximal run of top-level `f.push(e)` statements in `container`'s sole
	 * constructor, keyed back to the empty-array field it fills. Only the FIRST run of a given
	 * field can ever be accepted — a second one has the first's occurrences behind it, which the
	 * no-earlier-observation gate refuses — so one field can never be folded twice into edits that
	 * would both rewrite its literal.
	 */
	private static function scanConstructor(container: QueryNode, ctx: Ctx, out: Array<Match>): Void {
		final s: Seams = ctx.seams;
		final bodyKind: Null<String> = s.blockBodyKind;
		final containerSpan: Null<Span> = container.span;
		if (bodyKind == null || containerSpan == null || s.fieldDeclKinds.length == 0) return;
		final ctor: Null<QueryNode> = CtorFieldWrite.soleConstructor(container, s.shape);
		if (ctor == null) return;
		final resolved: QueryNode = ctor;
		final body: Null<QueryNode> = resolved.children.find(c -> c.kind == bodyKind);
		if (body == null) return;
		final kids: Array<QueryNode> = body.children;
		final statics: Array<Int> = MemberKinds.staticMemberFroms(container, s.shape);
		var i: Int = 0;
		while (i < kids.length) {
			final push: Null<Push> = pushStatement(kids[i], ctx);
			if (push == null) {
				i++;
				continue;
			}
			final run: Array<Push> = [push];
			var next: Int = i + 1;
			while (next < kids.length) {
				final more: Null<Push> = pushStatement(kids[next], ctx);
				if (more == null || more.name != push.name) break;
				run.push(more);
				next++;
			}
			final m: Null<Match> = fieldMatch(container, resolved, body, containerSpan, statics, run, ctx);
			if (m != null) out.push(m);
			i = next;
		}
	}

	/**
	 * Path B's gates on a constructor push run, and the fold when they all hold. The order is
	 * cheap-first: the field shape and the textual scans settle most runs before the write index
	 * or the purity context is ever forced.
	 */
	private static function fieldMatch(
		container: QueryNode, ctor: QueryNode, body: QueryNode, containerSpan: Span, statics: Array<Int>, run: Array<Push>, ctx: Ctx
	): Null<Match> {
		final s: Seams = ctx.seams;
		final source: String = ctx.source;
		final name: String = run[0].name;
		final field: Null<FieldDecl> = emptyArrayField(container, name, statics, ctx);
		final ctorSpan: Null<Span> = ctor.span;
		final owner: Null<String> = container.name;
		if (field == null || ctorSpan == null || owner == null) return null;
		final decl: FieldDecl = field;
		final from: Int = run[0].stmt.from;
		final end: Int = run[run.length - 1].stmt.to;
		if (!receiversDenoteField(run, container, decl.span.from, ctx)) return null;
		if (CheckScan.hasCommentMarker(source, decl.span.from, decl.span.to)) return null;
		if (CheckScan.hasCommentMarker(source, from, endOfLine(source, end))) return null;
		if (OccurrenceScan.referencedInRange(source, name, ctorSpan.from, from, [])) return null;
		// The field's OWN declaration is excluded: a field declared BELOW the constructor lies in
		// this range and would satisfy the read-after gate with nothing but itself.
		if (!OccurrenceScan.referencedInRange(source, name, end, containerSpan.to, [decl.span])) return null;
		if (!CtorFieldWrite.ctorPrefixUnconditional(ctor, from, s.shape)) return null;
		if (!prologueRunsNoCode(body, from, s)) return null;
		final writes: FieldWriteIndex = ctx.writes();
		if (writes.hasUnresolvedWrite(name) || writes.writeCount(owner, name) != NO_WRITES) return null;
		if (constructorCallsUp(ctor, s) && overrideMemberReads(container, name, ctx)) return null;
		if (!elementsMoveSafely(run, container, statics, ctx)) return null;
		final edits: Array<{ span: Span, text: String }> = foldEdits(decl.literal, run, ctx);
		return { span: decl.span, edits: edits };
	}

	/**
	 * Whether the constructor prologue before `boundary` runs NO code of its own: no top-level
	 * statement lexically before the run may contain a call or a `new` anywhere in its subtree.
	 *
	 * The hazard the purity gate cannot reach. Purity proves the ELEMENTS observe nothing; it says
	 * nothing about what the prologue observes. A plain `log();` before the run — a method that
	 * reads the field's `length` — sees an EMPTY array today and the filled one after the fold, and
	 * no other gate looks at it. The `super(...)` statement is the ONE exemption: crossing it is
	 * governed by the override-read gate instead, which is the only way a base constructor can see
	 * back into this class.
	 *
	 * Two residuals, NAMED rather than gated. A prologue ASSIGNMENT whose l-value is a property
	 * whose SETTER reads the field is invisible here — the statement holds no call node, the call is
	 * the accessor the compiler inserts. And the exemption covers the whole `super(...)` STATEMENT,
	 * its ARGUMENTS included, so a `super(f())` whose `f` reads the field is not seen either.
	 *
	 * `newExprKind` unset disarms Path B rather than admitting an unrecognisable `new` — a
	 * construction is exactly the arbitrary code this gate exists to refuse.
	 */
	private static function prologueRunsNoCode(body: QueryNode, boundary: Int, s: Seams): Bool {
		if (s.newExprKind == null) return false;
		for (stmt in body.children) {
			final span: Null<Span> = stmt.span;
			if (span == null) return false;
			if (span.from >= boundary) return true;
			if (!isSuperCallStatement(stmt, s) && runsCode(stmt, s)) return false;
		}
		return true;
	}

	/** Whether `stmt` is exactly the base-constructor call statement `super(...);`. */
	private static function isSuperCallStatement(stmt: QueryNode, s: Seams): Bool {
		final superText: Null<String> = s.superText;
		if (superText == null || stmt.kind != s.exprStmtKind || stmt.children.length != 1) return false;
		final call: QueryNode = stmt.children[0];
		if (call.kind != s.callKind || call.children.length == 0) return false;
		final callee: QueryNode = call.children[0];
		return callee.kind == s.identKind && callee.name == superText;
	}

	/** Whether `node`'s subtree holds a call or a construction — anything that runs code of its own. */
	private static function runsCode(node: QueryNode, s: Seams): Bool {
		return node.kind == s.callKind || node.kind == s.newExprKind || node.children.exists(child -> runsCode(child, s));
	}

	/** The offset of the newline ending `at`'s line, or the source length when it is the last line. */
	private static function endOfLine(source: String, at: Int): Int {
		var to: Int = at;
		while (to < source.length && source.fastCodeAt(to) != '\n'.code) to++;
		return to;
	}

	/**
	 * Whether every UNQUALIFIED push receiver of `run` resolves to the field declared at `fieldFrom`.
	 * A `this.`-qualified one names the member outright and needs no resolution; a bare one could be a
	 * same-named constructor local or parameter, which would otherwise be folded into the field.
	 */
	private static function receiversDenoteField(run: Array<Push>, container: QueryNode, fieldFrom: Int, ctx: Ctx): Bool {
		final shape: RefShape = ctx.seams.shape;
		return run.foreach(
			push -> push.qualified || TypeResolver.resolveBindingFrom(push.name, push.receiver, container, shape) == fieldFrom
		);
	}

	/**
	 * Whether every element of `run` may be evaluated in the declaration prologue instead: no
	 * self-reference to the array being built, provably no observable effect (`constantElement`), and
	 * legal plus context-independent where it is moving (`RefactorSupport.contextFreeRhs`). With no
	 * purity context — the grammar leaves a seam unset, or no symbol index reached this run — the
	 * answer is false, so Path B goes silent rather than guessing.
	 */
	private static function elementsMoveSafely(run: Array<Push>, container: QueryNode, statics: Array<Int>, ctx: Ctx): Bool {
		final s: Seams = ctx.seams;
		final purity: Null<PurityCtx> = ctx.purity();
		if (purity == null) return false;
		final scan: PurityCtx = purity;
		for (push in run) {
			if (referencesName(push.arg, push.name, s)) return false;
			if (!constantElement(push.arg, scan, s)) return false;
			if (!CtorFieldWrite.contextFreeRhs(push.arg, container, statics, s.shape, true, _ -> true)) return false;
		}
		return true;
	}

	/**
	 * The instance field of `container` named `name` whose declaration initializer is the empty
	 * array literal, or null. A name declared MORE THAN ONCE (only reachable across mutually
	 * exclusive `#if` branches) is refused outright — the fold would fill one branch's literal and
	 * strip the other branch's pushes. A `(` in the declaration head is the same conservative
	 * over-skip `field-init-at-declaration` takes: it bars a property, whose accessors this rule
	 * cannot reason about, and a function-type field.
	 */
	private static function emptyArrayField(container: QueryNode, name: String, statics: Array<Int>, ctx: Ctx): Null<FieldDecl> {
		final s: Seams = ctx.seams;
		final declared: Array<QueryNode> = [];
		MemberKinds.eachMemberHost(container, host -> for (member in host.children) if (
			s.memberDeclKinds.contains(member.kind) && member.name == name
		)
			declared.push(member));
		if (declared.length != 1) return null;
		final member: QueryNode = declared[0];
		final span: Null<Span> = member.span;
		if (span == null || !s.fieldDeclKinds.contains(member.kind) || member.children.length != 1) return null;
		if (statics.contains(span.from)) return null;
		final literal: Null<Span> = emptyArraySpan(member.children[0], s);
		if (literal == null || ctx.source.substring(span.from, literal.from).indexOf('(') >= 0) return null;
		if (!annotationNamesArray(span, literal, name, ctx)) return null;
		final proven: Span = literal;
		return { span: span, literal: proven };
	}

	/**
	 * Whether the constructor calls its base constructor. Fails CLOSED with `superReferenceText`
	 * unset: an unrecognisable call is read as present, which arms the override-reader gate rather
	 * than skipping it.
	 */
	private static function constructorCallsUp(ctor: QueryNode, s: Seams): Bool {
		final superText: Null<String> = s.superText;
		if (superText == null) return true;
		final calls: Array<QueryNode> = [];
		CtorFieldWrite.collectSuperCalls(ctor, superText, s.callKind, s.identKind, calls);
		return calls.length > 0;
	}

	/**
	 * Whether any `override` member of `container` mentions `name` — the one read a base
	 * constructor can reach through a virtual call. Textual within the member's span, so a `$f`
	 * interpolation and a mention inside a nested closure both count. Fails CLOSED with
	 * `overrideModifierKind` unset.
	 *
	 * `macroModifierPrecedes` is named for its first consumer; what it actually answers is "does a
	 * modifier of KIND K precede this member in its modifier run", which is exactly the override
	 * question — modifiers project as separate childless siblings before the member they modify.
	 */
	private static function overrideMemberReads(container: QueryNode, name: String, ctx: Ctx): Bool {
		final s: Seams = ctx.seams;
		final overrideKind: Null<String> = s.overrideKind;
		if (overrideKind == null) return true;
		var reads: Bool = false;
		MemberKinds.eachMemberHost(container, host -> {
			final kids: Array<QueryNode> = host.children;
			for (i in 0...kids.length) {
				if (reads) return;
				final span: Null<Span> = kids[i].span;
				if (span == null || !s.memberDeclKinds.contains(kids[i].kind)) continue;
				if (!MemberKinds.macroModifierPrecedes(kids, i, overrideKind, sib -> s.memberDeclKinds.contains(sib.kind))) continue;
				if (OccurrenceScan.referencedInRange(ctx.source, name, span.from, span.to, [])) reads = true;
			}
		});
		return reads;
	}

	/**
	 * Whether evaluating `node` has no observable effect OF ITS OWN: side-effect-free by
	 * `PurityScan`, or a COLLECTION LITERAL whose every child is. It says nothing about whether
	 * some OTHER code can observe the array filling earlier — that is the prologue and
	 * virtual-read gates' question, not this one's.
	 *
	 * The literal is admitted here rather than inside `PurityScan` for the reason
	 * `unnecessary-switch` gives for the same split — the safe direction differs per caller. This
	 * rule evaluates each element exactly once and merely earlier, so an allocation is neither
	 * dropped nor shared between two references; a caller that HOISTS a repeated expression would
	 * be merging two allocations into one and must not admit it.
	 */
	private static function constantElement(node: QueryNode, purity: PurityCtx, s: Seams): Bool {
		return !s.collectionKinds.contains(node.kind)
			? PurityScan.isPure(node, purity)
			: node.children.foreach(child -> constantElement(child, purity, s));
	}

	/**
	 * Whether any identifier in `node`'s subtree carries `name` — the self-reference test. A
	 * `$name` string interpolation counts: it projects as its own identifier kind, and
	 * `out.push('$out')` reads the array being built exactly as a bare `out` would. A reification
	 * subtree answers TRUE, since nothing about its contents can be proven.
	 */
	private static function referencesName(node: QueryNode, name: String, s: Seams): Bool {
		return s.opaqueKinds.contains(node.kind) || node.name == name && (node.kind == s.identKind || node.kind == s.interpIdentKind)
			|| node.children.exists(child -> referencesName(child, name, s));
	}

	/**
	 * The fold: one edit replacing the empty literal with the assembled one, and one whole-line
	 * deletion per push statement. Element text is sliced VERBATIM from each push argument's span.
	 * The deletions cannot overlap each other or the literal — each extends backward only to the
	 * end of the previous line, and the literal lies before the first push.
	 */
	private static function foldEdits(literal: Span, run: Array<Push>, ctx: Ctx): Array<{ span: Span, text: String }> {
		final elements: Array<String> = [for (push in run) ctx.source.substring(push.argSpan.from, push.argSpan.to)];
		final edits: Array<{ span: Span, text: String }> = [{ span: literal, text: '[${elements.join(', ')}]' }];
		for (push in run) edits.push({ span: CheckScan.lineDeletionSpan(ctx.source, push.stmt), text: '' });
		return edits;
	}

	/** A memoised `FieldWriteIndex` builder — built at most once, and only when a Path B run reaches its gate. */
	private static function lazyWriteIndex(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): () -> FieldWriteIndex {
		var index: Null<FieldWriteIndex> = null;
		return () -> {
			final ready: Null<FieldWriteIndex> = index;
			if (ready != null) return ready;
			final built: FieldWriteIndex = FieldWriteIndex.build(files, plugin);
			index = built;
			return built;
		};
	}

}

/** The `RefShape` kinds `JoinArrayPushes` reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	var shape: RefShape;
	var identKind: String;
	var callKind: String;
	var fieldAccessKind: String;
	var exprStmtKind: String;
	var arrayLiteralKind: String;
	var blockKinds: Array<String>;
	var localDeclKinds: Array<String>;
	var continuationKinds: Array<String>;
	var blockBodyKind: Null<String>;
	var fieldDeclKinds: Array<String>;
	var memberDeclKinds: Array<String>;
	var classLikeKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var interpIdentKind: String;
	var newExprKind: Null<String>;
	var arrayTypeNames: Array<String>;
	var selfText: Null<String>;
	var superText: Null<String>;
	var overrideKind: Null<String>;
	var collectionKinds: Array<String>;
}

/**
 * Per-file inputs the walkers share: the source, the resolved seams, and the two lazily-forced
 * indexes only Path B needs — the cross-file field-write index and the purity context.
 */
private typedef Ctx = {
	var source: String;
	var seams: Seams;
	var writes: () -> FieldWriteIndex;
	var purity: () -> Null<PurityCtx>;
}

/** A Path A array declaration: the bound name, the declaration statement's span and its empty literal's span. */
private typedef LocalDecl = {
	var name: String;
	var span: Span;
	var literal: Span;
}

/** A Path B array field: its declaration span (what the finding reports) and its empty literal's span. */
private typedef FieldDecl = {
	var span: Span;
	var literal: Span;
}

/**
 * One `<name>.push(e);` statement of a run: the receiver name, the statement's span (deleted by
 * the fix), the argument node and span (the element), the receiver's own span (resolved against
 * the field declaration on Path B) and whether the receiver was written `this.<name>`.
 */
private typedef Push = {
	var name: String;
	var stmt: Span;
	var arg: QueryNode;
	var argSpan: Span;
	var receiver: Span;
	var qualified: Bool;
}

/** One foldable binding: the span the finding reports and the edits that fold it. */
private typedef Match = {
	var span: Span;
	var edits: Array<{ span: Span, text: String }>;
}

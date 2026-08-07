package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

using Lambda;

/**
 * Flags a null guard that safe navigation (`?.`) replaces. Three arms:
 *
 * - STATEMENT — `if (x != null) x.m(...)` (and the braced `if (x != null) { x.m(...); }`,
 *   plus the reversed `if (null != x) …`) collapses to `x?.m(...);`. A CONJUNCTION guard
 *   `if (C && ... && x != null) x.m(...)` drops the null-check, keeping the rest:
 *   `if (C && ...) x?.m(...)`.
 * - TERNARY — `x == null ? null : x.m(...)` and its dual `x != null ? x.m(...) : null`
 *   (either polarity, the `null` operand on either side of the comparison) collapse to
 *   `x?.m(...)`, the EXPRESSION form of the same guard. `?.` short-circuits the whole
 *   receiver chain, so a multi-step body (`x.map(f).join(',')`, `x.arr[0].c`) collapses
 *   in one step exactly like the statement arm.
 * - ASSIGNMENT — a local declared `= null` immediately followed by its guarded assignment,
 *   `var r:Null<T> = null; if (x != null) r = x.chain(...);`, folds into the declaration as
 *   `var r:Null<T> = x?.chain(...);`. Sound ONLY in that adjacency: the fold makes the
 *   guard's false path assign `null`, which is exactly what the `null` initializer already
 *   gave it. The guard must be the SOLE condition (nothing survives the removed `if`), and
 *   the assigned local may not appear in the right-hand side — the declaration would then
 *   reference itself.
 *
 * `Severity.Info` (a modernization cleanup), with an autofix.
 *
 * ## The guard SUBJECT — a plain identifier or a one-step `<ident>.<field>` path
 *
 * `x` above stands for the guard SUBJECT, which `subjectOf` admits in two shapes: a plain
 * identifier, and a one-step field path reached by a plain `.` (`fld.parent != null`,
 * `this.fld != null`). A DEEPER path (`a.b.c`) refuses — each step would need its own
 * proof — and so does an already-safe `x?.f`, which projects as another kind and is the
 * dead- / unnecessary-safe-nav checks' territory.
 *
 * ## Soundness — an accessor-free subject, a CALL body, no else, `x` only as the root
 *
 * `if (r != null) r.m()` reads `r` twice, `r?.m()` once — so a subject whose read RUNS
 * CODE would change semantics. The guard is flagged only when the subject is proven
 * accessor-free. For the ROOT identifier that is three receiver classes:
 *
 * - a LOCAL declaration (`localDeclKinds`) or a PARAMETER (`paramKinds`) whose scope
 *   encloses the use and that lexically precedes it — a local can carry no accessor;
 * - the SELF reference (`selfReferenceText`, projected as a plain identifier named `this`)
 *   — a keyword denoting the current object, in an ABSTRACT the underlying value, which is
 *   where a nullable `this` actually occurs. That is what unlocks the abstract idiom
 *   `@:to function toString() return this == null ? null : this.map(f).join(',');`;
 * - a FIELD the enclosing type declares as a physical `var` / `final` (`fieldDeclKinds`)
 *   with no read accessor. A Haxe field cannot be redeclared by a subtype, so a plain field
 *   stays plain at every use of the type — the double read is a no-op there too. A
 *   `(get, …)` / `dynamic` property, a member of any other kind, a name the enclosing type
 *   does not itself declare, and an `extern` host all refuse (see `fieldProver`).
 *
 * A one-step path reads BOTH parts twice, so it needs the root proof AND a second one for
 * the step: `TypeResolver.isPlainFieldRead` against the run's resolution-scoped index,
 * which resolves the root's declared type and walks its supertypes for the member's
 * accessor shape. A getter property, a type the index cannot resolve, and a run with no
 * resolution scope at all each leave the step unproven, and the guard unflagged. That proof
 * reads the member's DECLARED shape, so — unlike the enclosing-type field proof above — it
 * does not carry an extern gate: an `extern` host whose `var` is a foreign slot is admitted
 * when the index resolves it. Tightening that belongs in the shared predicate, not here.
 *
 * The then-branch must be exactly ONE expression statement — a CALL for the statement arm,
 * the guarded local's assignment for the assignment arm — whose expression is a plain chain
 * rooted at the guard subject (`x.m(...)` / `x.a.b(...)` — see `subjectAccess` below), so:
 *
 * - a multi-statement block is NOT flagged (the user groups those under one `if`
 *   deliberately);
 * - an assignment l-value (`x.f = v`) is NOT flagged — `x?.f = v` does not
 *   compile;
 * - a body already using `?.` on the root (`x?.m()`) is NOT flagged — its first
 *   access projects as `nullSafeAccessKind`, not `fieldAccessKind` (the dead- /
 *   unnecessary-safe-nav checks' territory);
 * - an `else` branch makes the guard a real two-way choice — NOT flagged;
 * - the guard subject appearing in the body anywhere but the chain root
 *   (`x.m(x)`, `x.a(x).b()`, `x.arr[x]`) is NOT flagged — after `x?.` it stays
 *   typed `Null<T>`, breaking `@:nullSafety(Strict)`. A subject rooted at a LOCAL
 *   counts as a WHOLE, so its bare root elsewhere (`x.f?.m(x)`) is fine — the guard
 *   never narrowed it. A member of the ENCLOSING object is the exception: `f` and
 *   `this.f` are one narrowed value under two spellings, so either spelling elsewhere
 *   in the body refuses the guard (`denotesSubject`).
 *
 * ## Conjunction — the null-check must be the LAST conjunct
 *
 * Conjuncts evaluate left-to-right, so a conjunct AFTER `x != null` may rely on
 * `x` being non-null (`if (x != null && x.len > 0) …`). Only a null-check that is
 * the LAST conjunct is dropped, leaving the preceding conjuncts as the surviving
 * `if` condition (kept verbatim, so a comment inside them is preserved). The assignment
 * arm takes no conjunction at all — its `if` disappears entirely, leaving nowhere to keep
 * the surviving conjuncts.
 *
 * ## The kept region must BE the chain — `subjectAccess`, shared by every arm
 *
 * The rewrite replaces the whole guard with the kept region, so that region has to be the
 * receiver chain itself and nothing more. `subjectAccess` therefore descends the
 * `children[0]` receiver spine through CHAIN steps only (`chainKinds` — `fieldAccessKind`,
 * `callKind`, `indexAccessKind`) until the receiver IS the subject, and the junction off it
 * must be a plain `.` (`fieldAccessKind`), so an index root (`x[0].f`) and an already-safe
 * `x?.f` root are left alone. `?.` short-circuits every chain step after it, so an index or
 * a call MID-chain (`x.arr[0].c`, `x.map(f).join(',')`) collapses fine — but a `cast`, a
 * parenthesis, an ascription or an operator on the spine does NOT: `(cast x.a).m()` would
 * become `(cast x?.a).m()`, which dereferences null, and `x == null ? null : x.f + 1` would
 * become `x?.f + 1`, which adds to a `Null<T>`. A spine node outside `chainKinds` ends the
 * descent with no match, which refuses all of those by construction.
 *
 * The ternary arm additionally requires the OTHER branch to be exactly the `null` literal;
 * `x == null ? 0 : x.f` guards a real fallback value, which is `prefer-null-coalescing`
 * territory at most. The kept branch keeps the type the ternary already had — `?.` yields
 * `Null<T>` just as the `null` branch did.
 *
 * ## Autofix
 *
 * The whole `if` statement (or the whole ternary) is replaced by the body statement /
 * guarded branch — for the statement arm optionally under `if (<surviving condition>)`
 * (conjunction) — with the FIRST dot off the guard subject turned into `?.`
 * (`if (x != null) x.a.b();` → `x?.a.b();`, `if (x.f != null) x.f.b();` → `x.f?.b();`):
 * only the guard being removed is encoded, inner nullables stay the author's concern.
 * The assignment arm instead emits TWO edits — the declaration's `null` becomes the
 * safe-nav chain and the whole `if` is deleted. A comment inside a DROPPED part of the
 * removed region would be lost, so such a guard is left unflagged; a comment between the
 * subject and its dot would SWALLOW the inserted `?`, so that one leaves the guard
 * reported but unfixed.
 *
 * ## Grammar-agnostic
 *
 * Driven by `ifStatementKinds`, `notEqKind`, `nullLiteralKind`, `callKind`,
 * `fieldAccessKind`, `exprStatementKind`, `blockStmtKind` (any unset → no-op),
 * plus `logicalAndKind` for the conjunction form, `ternaryKind` for the ternary arm
 * (unset → that arm alone is off) with `eqKind` adding its `x == null ? null : …`
 * polarity, `assignKind` for the assignment arm (unset → that arm alone is off),
 * `indexAccessKind` for an index step on a chain, `selfReferenceText` for the
 * `this` receiver, `localDeclKinds` / `paramKinds` / `scopeKinds` for the binding
 * resolution, `fieldDeclKinds` / `externModifierKind` plus a `TypeInfoProvider` plugin for
 * the field receiver (any missing → fields refuse), `parenKind` to unwrap a parenthesized
 * condition or ternary branch, and `opaqueKinds` to skip reification subtrees. The one-step
 * path arm additionally needs the `TypeInfoProvider` declared-type sources and a
 * `SymbolIndex` (`RefactorSupport.lazySymbolIndex`); without either, only plain-identifier
 * subjects are flagged.
 */
@:nullSafety(Strict)
final class PreferSafeNav implements Check {

	/** An `if` with no `else` has exactly [condition, then-branch] children. */
	private static inline final IF_NO_ELSE_CHILD_COUNT: Int = 2;

	/** A binary comparison node has exactly [left, right] children. */
	private static inline final COMPARISON_CHILD_COUNT: Int = 2;

	/** A logical-AND node has exactly [preceding-conjuncts, last-conjunct] children. */
	private static inline final AND_CHILD_COUNT: Int = 2;

	/** A complete ternary node has exactly [condition, then-branch, else-branch] children. */
	private static inline final TERNARY_CHILD_COUNT: Int = 3;

	/** An assignment node has exactly [l-value, r-value] children. */
	private static inline final ASSIGN_CHILD_COUNT: Int = 2;

	public function new() {}

	public function id(): String {
		return 'prefer-safe-nav';
	}

	public function description(): String {
		return 'a null guard (if (x != null) x.m(), x == null ? null : x.m()) replaceable with safe navigation (x?.m())';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		final getIndex: () -> Null<SymbolIndex> = RefactorSupport.lazySymbolIndex(files, plugin);
		final shape: RefShape = plugin.refShape();
		for (entry in files) {
			final parsed: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (parsed == null) continue;
			final tree: QueryNode = parsed;
			final bindings: Array<{ name: String, scope: Span, declEnd: Int }> = [];
			collectBindings(tree, null, seams, bindings);
			final declaredTypes: () -> Map<Int, String> = TypeResolver.memoizedDeclaredTypeSources(plugin, entry.source);
			final plainRead: QueryNode -> Bool = subject -> {
				final index: Null<SymbolIndex> = getIndex();
				return index != null && TypeResolver.isPlainFieldRead(subject, tree, shape, declaredTypes(), index);
			};
			walk(tree, violations, entry.file, entry.source, bindings, fieldProver(tree, entry.source, plugin, seams), plainRead, seams);
		}
		return violations;
	}

	/**
	 * Rewrite each flagged guard to `<root>?.<rest>`: the statement and ternary arms replace the whole `if` statement / ternary in place, the assignment arm folds the chain into the null initializer of the declaration above and deletes the `if`.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final s: Seams = seams;
		final ternaryKind: Null<String> = s.ternaryKind;
		final spanIndexKinds: Array<String> = ternaryKind == null ? s.ifKinds : s.ifKinds.concat([ternaryKind]);
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		final assigns: Map<String, AssignGuard> = [];
		if (tree != null) collectAssignGuards(tree, source, s, assigns);
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final guard: Null<AssignGuard> = assigns['${span.from}:${span.to}'];
			if (guard == null) continue;
			final pair: Null<Array<{ span: Span, text: String }>> = assignEdits(guard, source);
			if (pair != null) for (e in pair) edits.push(e);
		}
		for (e in CheckScan.applyBySpan(plugin, source, violations, spanIndexKinds, (node, span) -> {
			// An `if` the ASSIGNMENT arm owns is folded into its declaration above, not rewritten
			// in place — its statement-arm reading (if any) must not also fire.
			if (assigns.exists('${span.from}:${span.to}')) return null;
			final m: Null<Candidate> = candidate(node, source, s);
			if (m == null) return null;
			final stmtSpan: Null<Span> = m.stmt.span;
			final rootSpan: Null<Span> = m.rootIdent.span;
			if (stmtSpan == null || rootSpan == null) return null;
			final body: Null<String> = safeNavText(source, rootSpan, stmtSpan);
			if (body == null) return null;
			final rest: Null<QueryNode> = m.restCond;
			final restSpan: Null<Span> = rest?.span;
			if (rest != null && restSpan == null) return null;
			final text: String = restSpan != null ? 'if (${StringTools.trim(source.substring(restSpan.from, restSpan.to))}) $body' : body;
			return { span: span, text: text };
		})) edits.push(e);
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Bundle the required + optional `RefShape` kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final ifKinds: Null<Array<String>> = shape.ifStatementKinds;
		if (ifKinds == null || ifKinds.length == 0) return null;
		final notEqKind: Null<String> = shape.notEqKind;
		if (notEqKind == null) return null;
		final nullKind: Null<String> = shape.nullLiteralKind;
		if (nullKind == null) return null;
		final callKind: Null<String> = shape.callKind;
		if (callKind == null) return null;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		if (fieldAccessKind == null) return null;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		if (exprStmtKind == null) return null;
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		if (blockStmtKind == null) return null;
		final chainKinds: Array<String> = [fieldAccessKind, callKind];
		final indexAccessKind: Null<String> = shape.indexAccessKind;
		if (indexAccessKind != null) chainKinds.push(indexAccessKind);
		return {
			ifKinds: ifKinds,
			notEqKind: notEqKind,
			nullKind: nullKind,
			identKind: shape.identKind,
			callKind: callKind,
			fieldAccessKind: fieldAccessKind,
			exprStmtKind: exprStmtKind,
			blockStmtKind: blockStmtKind,
			parenKind: shape.parenKind,
			scopeKinds: shape.scopeKinds,
			opaqueKinds: shape.opaqueKinds ?? [],
			localDeclKinds: shape.localDeclKinds ?? [],
			paramKinds: shape.paramKinds ?? [],
			andKind: shape.logicalAndKind,
			ternaryKind: shape.ternaryKind,
			eqKind: shape.eqKind,
			chainKinds: chainKinds,
			selfText: shape.selfReferenceText,
			assignKind: shape.assignKind,
			// The extern gate is what keeps a foreign slot's read out of the field proof, so a
			// grammar that cannot name its extern modifier gets no field receivers at all.
			fieldDeclKinds: shape.externModifierKind == null ? [] : shape.fieldDeclKinds ?? [],
			externKind: shape.externModifierKind,
			blockKinds: plugin.controlFlowSupport()?.blockKinds() ?? []
		};
	}

	/**
	 * Walk `node`, flagging each guard that `candidate` accepts and whose operand binds to a
	 * local / param / `this` / a proven plain field, plus each ASSIGNMENT-arm sibling pair
	 * (a null-initialized declaration immediately followed by its guarded assignment).
	 */
	private static function walk(
		node: QueryNode, out: Array<Violation>, file: String, source: String, bindings: Array<{ name: String, scope: Span, declEnd: Int }>,
		fieldOk: (String, Span) -> Bool, plainRead: QueryNode -> Bool, s: Seams
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		final m: Null<Candidate> = candidate(node, source, s);
		if (m != null && acceptedReceiver(m.condIdent, bindings, fieldOk, plainRead, s)) report(node, out, file);
		final kids: Array<QueryNode> = node.children;
		if (s.blockKinds.contains(node.kind)) for (i in 0...kids.length - 1) {
			final a: Null<AssignGuard> = assignGuard(kids[i], kids[i + 1], source, s);
			if (a != null && acceptedReceiver(a.condIdent, bindings, fieldOk, plainRead, s)) report(kids[i + 1], out, file);
		}
		for (c in kids) walk(c, out, file, source, bindings, fieldOk, plainRead, s);
	}

	/** Push the `Info` finding anchored at `node` — the guarding `if` statement, or the guarding ternary. */
	private static function report(node: QueryNode, out: Array<Violation>, file: String): Void {
		final span: Null<Span> = node.span;
		if (span != null) out.push({
			file: file,
			span: span,
			rule: 'prefer-safe-nav',
			severity: Severity.Info,
			message: 'this null guard can be safe navigation (?.)'
		});
	}

	/**
	 * The ASSIGNMENT arm: `decl` is a local declared `= null` and `ifNode` is the immediately
	 * following `if (x != null) r = x.chain(...)` assigning to exactly that local. Returns the
	 * guard when so, else null.
	 *
	 * Soundness rests entirely on the adjacent NULL initializer: the fold moves the assignment
	 * into the declaration, so the path where the guard is false must observe `null` — which is
	 * precisely what the declaration already gives it. Without the null-initialized adjacent
	 * declaration the arm is unsound and is not attempted. The shape gates live in
	 * `nullInitLocal` and `guardedChainAssignment`; what is decided here is the comment gate — a
	 * comment in the dropped `if` head or tail would be lost, so such a pair is left unflagged.
	 */
	private static function assignGuard(decl: QueryNode, ifNode: QueryNode, source: String, s: Seams): Null<AssignGuard> {
		final target: Null<{ name: String, nullLiteral: QueryNode }> = nullInitLocal(decl, s);
		if (target == null) return null;
		final found: Null<{ condIdent: QueryNode, rhs: QueryNode, root: QueryNode }> = guardedChainAssignment(ifNode, target.name, s);
		if (found == null) return null;
		final ifSpan: Null<Span> = ifNode.span;
		final rhsSpan: Null<Span> = found.rhs.span;
		if (ifSpan == null || rhsSpan == null) return null;
		final hasComment: Bool = CheckScan.hasCommentMarker(source, ifSpan.from, rhsSpan.from)
			|| CheckScan.hasCommentMarker(source, rhsSpan.to, ifSpan.to);
		return hasComment ? null : {
			condIdent: found.condIdent,
			ifNode: ifNode,
			rhs: found.rhs,
			rootIdent: found.root,
			nullLiteral: target.nullLiteral
		};
	}

	/**
	 * The name and `null` literal of a local declared exactly `= null` — the only declaration
	 * shape the assignment arm may fold into — or null for every other declaration.
	 */
	private static function nullInitLocal(decl: QueryNode, s: Seams): Null<{ name: String, nullLiteral: QueryNode }> {
		if (!s.localDeclKinds.contains(decl.kind) || decl.children.length != 1) return null;
		final nullLiteral: QueryNode = decl.children[0];
		final name: Null<String> = decl.name;
		return nullLiteral.kind != s.nullKind || name == null ? null : { name: name, nullLiteral: nullLiteral };
	}

	/**
	 * The `if (x != null) <declName> = x.chain(...)` shape `ifNode` carries, or null: an
	 * `else`-less guard whose SOLE condition null-checks a guard subject and whose sole
	 * statement assigns to exactly `declName` a chain rooted at that subject.
	 *
	 * A conjunction guard is refused — the `if` disappears entirely, leaving nowhere for the
	 * surviving conjuncts. `declName` may appear nowhere in the right-hand side, receiver
	 * included, or the fold would make the declaration reference itself.
	 */
	private static function guardedChainAssignment(
		ifNode: QueryNode, declName: String, s: Seams
	): Null<{ condIdent: QueryNode, rhs: QueryNode, root: QueryNode }> {
		final assignKind: Null<String> = s.assignKind;
		if (assignKind == null || !s.ifKinds.contains(ifNode.kind) || ifNode.children.length != IF_NO_ELSE_CHILD_COUNT) return null;
		final condIdent: Null<QueryNode> = guardOperand(ifNode.children[0], s);
		if (condIdent == null || subjectRoot(condIdent, s).name == declName) return null;
		final stmt: Null<QueryNode> = soleExprStatement(ifNode.children[1], s);
		if (stmt == null) return null;
		final assign: QueryNode = stmt.children[0];
		if (assign.kind != assignKind || assign.children.length != ASSIGN_CHILD_COUNT) return null;
		final lhs: QueryNode = assign.children[0];
		if (lhs.kind != s.identKind || lhs.name != declName) return null;
		final rhs: QueryNode = assign.children[1];
		final access: Null<QueryNode> = subjectAccess(rhs, condIdent, s);
		if (access == null) return null;
		final root: QueryNode = access.children[0];
		return mentionsOutsideRoot(rhs, root, condIdent, s) || mentionsOutsideRoot(rhs, root, lhs, s) ? null : {
			condIdent: condIdent,
			rhs: rhs,
			root: root
		};
	}

	/** Index every ASSIGNMENT-arm guard by its `if` statement's `from:to` span — the key `run` anchors its finding on. */
	private static function collectAssignGuards(node: QueryNode, source: String, s: Seams, out: Map<String, AssignGuard>): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		final kids: Array<QueryNode> = node.children;
		if (s.blockKinds.contains(node.kind)) for (i in 0...kids.length - 1) {
			final g: Null<AssignGuard> = assignGuard(kids[i], kids[i + 1], source, s);
			final span: Null<Span> = kids[i + 1].span;
			if (g != null && span != null) out['${span.from}:${span.to}'] = g;
		}
		for (c in kids) collectAssignGuards(c, source, s, out);
	}

	/** The two edits folding `g` into its declaration: the `null` initializer becomes the safe-nav chain, the whole `if` goes. */
	private static function assignEdits(g: AssignGuard, source: String): Null<Array<{ span: Span, text: String }>> {
		final ifSpan: Null<Span> = g.ifNode.span;
		final rhsSpan: Null<Span> = g.rhs.span;
		final rootSpan: Null<Span> = g.rootIdent.span;
		final nullSpan: Null<Span> = g.nullLiteral.span;
		if (ifSpan == null || rhsSpan == null || rootSpan == null || nullSpan == null) return null;
		final nav: Null<String> = safeNavText(source, rootSpan, rhsSpan);
		// The `if` occupies a whole line of its own in the common case; deleting the bare span
		// would leave that line behind as a blank one. `lineExtendedSpan` falls back to the bare
		// span when the statement shares its line, so a one-line `var r = null; if (…) …;` is safe.
		return nav == null ? null : [
			{ span: nullSpan, text: nav },
			{ span: RefactorSupport.lineExtendedSpan(source, ifSpan), text: '' }
		];
	}

	/**
	 * `region` verbatim with the FIRST dot off the receiver ending at `rootSpan` turned into
	 * `?.`, or null when there is no such dot inside the region or a comment sits between the
	 * receiver and it (the comment would swallow the inserted `?`).
	 */
	private static function safeNavText(source: String, rootSpan: Span, region: Span): Null<String> {
		final dotPos: Int = source.indexOf('.', rootSpan.to);
		if (dotPos < 0 || dotPos >= region.to || CheckScan.hasCommentMarker(source, rootSpan.to, dotPos)) return null;
		return '${source.substring(region.from, dotPos)}?.${source.substring(dotPos + 1, region.to)}';
	}

	/** The candidate `node` yields — the `if`-statement guard or the ternary guard, whichever arm its kind selects. */
	private static function candidate(node: QueryNode, source: String, s: Seams): Null<Candidate> {
		if (s.ifKinds.contains(node.kind)) return match(node, source, s);
		return node.kind == s.ternaryKind ? matchTernary(node, source, s) : null;
	}

	/**
	 * If `ternary` is a null guard whose guarded branch is exactly a receiver chain rooted
	 * at the guard subject — `x == null ? null : x.chain(...)` or its dual
	 * `x != null ? x.chain(...) : null` — return that guard; else null. The other branch
	 * must be the bare `null` literal, the chain must reach the subject through plain
	 * `.` / call / index steps only (so `x.f + 1` is refused), the subject must not
	 * appear anywhere in the branch but at the chain root, and no comment may sit in the
	 * dropped text around the branch.
	 */
	private static function matchTernary(ternary: QueryNode, source: String, s: Seams): Null<Candidate> {
		if (ternary.children.length != TERNARY_CHILD_COUNT) return null;
		final cond: QueryNode = RefactorSupport.unwrapParens(ternary.children[0], s.parenKind);
		if (cond.children.length != COMPARISON_CHILD_COUNT) return null;
		// `==` puts `null` in the THEN branch and the guarded chain in the ELSE branch; `!=` mirrors that.
		final elseIsGuarded: Bool = cond.kind == s.eqKind;
		if (!elseIsGuarded && cond.kind != s.notEqKind) return null;
		final condIdent: Null<QueryNode> = subjectOperand(cond, s);
		if (condIdent == null) return null;
		final branch: QueryNode = RefactorSupport.unwrapParens(ternary.children[elseIsGuarded ? 2 : 1], s.parenKind);
		final fallback: QueryNode = RefactorSupport.unwrapParens(ternary.children[elseIsGuarded ? 1 : 2], s.parenKind);
		if (fallback.kind != s.nullKind) return null;
		final access: Null<QueryNode> = subjectAccess(branch, condIdent, s);
		if (access == null) return null;
		if (mentionsOutsideRoot(branch, access.children[0], condIdent, s)) return null;
		final ternarySpan: Null<Span> = ternary.span;
		final branchSpan: Null<Span> = branch.span;
		if (ternarySpan == null || branchSpan == null) return null;
		final hasComment: Bool = CheckScan.hasCommentMarker(source, ternarySpan.from, branchSpan.from)
			|| CheckScan.hasCommentMarker(source, branchSpan.to, ternarySpan.to);
		return hasComment ? null : {
			condIdent: condIdent,
			stmt: branch,
			rootIdent: access.children[0],
			restCond: null
		};
	}

	/** The guard SUBJECT of a `<subject> <op> null` / `null <op> <subject>` comparison, or null for any other shape. */
	private static function subjectOperand(cond: QueryNode, s: Seams): Null<QueryNode> {
		final a: QueryNode = cond.children[0];
		final b: QueryNode = cond.children[1];
		if (a.kind == s.nullKind) return subjectOf(b, s);
		return b.kind == s.nullKind ? subjectOf(a, s) : null;
	}

	/**
	 * `node` when it is a guard SUBJECT — a plain identifier, or a one-step `<ident>.<field>`
	 * path whose junction is a plain `.` — else null. A deeper path (`a.b.c`) and an already-safe
	 * `x?.f` project as other shapes and refuse: the first would need a proof per step, the
	 * second is the dead- / unnecessary-safe-nav checks' territory.
	 */
	private static function subjectOf(node: QueryNode, s: Seams): Null<QueryNode> {
		if (node.kind == s.identKind) return node;
		return node.kind == s.fieldAccessKind && node.children.length == 1 && node.children[0].kind == s.identKind ? node : null;
	}

	/**
	 * Descend `node`'s receiver spine through CHAIN steps only (`chainKinds` — field access,
	 * call, index) until the receiver IS `subject`, returning the step that directly holds it,
	 * and only when that step is a plain `.` field access. Null when `node` is not a chain at
	 * all (`x.f + 1`), when the spine bottoms out without meeting the subject, or when the
	 * junction off it is an index / already-safe access.
	 */
	private static function subjectAccess(node: QueryNode, subject: QueryNode, s: Seams): Null<QueryNode> {
		var n: QueryNode = node;
		while (s.chainKinds.contains(n.kind) && n.children.length > 0) {
			if (sameSubject(n.children[0], subject, s)) return n.kind == s.fieldAccessKind ? n : null;
			n = n.children[0];
		}
		return null;
	}

	/**
	 * If `ifNode` is a no-`else` guard whose then-branch is a single call statement
	 * rooted at the guard subject `x` reached by a plain `.`, return the guard
	 * operand, the body statement, the chain-root subject and the surviving
	 * condition (`restCond`, null for a sole guard); else null. Two condition shapes:
	 * `if (x != null) x.chain(...)` (sole) and `if (C && ... && x != null) x.chain(...)`
	 * (the null-check is the LAST conjunct — see `guardCondition`). Bails when `x`
	 * appears in the call ARGUMENTS (`x.m(x)` — `x?.m(x)` would leave it `Null<T>`),
	 * and when a comment sits in a DROPPED part of the removed `if` region.
	 */
	private static function match(ifNode: QueryNode, source: String, s: Seams): Null<Candidate> {
		if (ifNode.children.length != IF_NO_ELSE_CHILD_COUNT) return null;
		final guard: Null<{ operand: QueryNode, rest: Null<QueryNode> }> = guardCondition(ifNode.children[0], s);
		if (guard == null) return null;
		final condIdent: QueryNode = guard.operand;
		final rest: Null<QueryNode> = guard.rest;
		final stmt: Null<QueryNode> = singleCallStatement(ifNode.children[1], s);
		if (stmt == null) return null;
		final access: Null<QueryNode> = subjectAccess(stmt.children[0], condIdent, s);
		if (access == null) return null;
		final root: QueryNode = access.children[0];
		if (mentionsOutsideRoot(stmt.children[0], root, condIdent, s)) return null;
		final ifSpan: Null<Span> = ifNode.span;
		final stmtSpan: Null<Span> = stmt.span;
		if (ifSpan == null || stmtSpan == null) return null;
		final restSpan: Null<Span> = rest != null ? rest.span : null;
		if (rest != null && restSpan == null) return null;
		final headHasComment: Bool = if (restSpan != null)
			CheckScan.hasCommentMarker(source, ifSpan.from, restSpan.from) || CheckScan.hasCommentMarker(source, restSpan.to, stmtSpan.from);
		else
			CheckScan.hasCommentMarker(source, ifSpan.from, stmtSpan.from);
		final hasComment: Bool = headHasComment || CheckScan.hasCommentMarker(source, stmtSpan.to, ifSpan.to);
		return hasComment ? null : {
			condIdent: condIdent,
			stmt: stmt,
			rootIdent: root,
			restCond: rest
		};
	}

	/**
	 * Whether `subject` is a receiver whose double read is provably free: the self reference
	 * (a keyword, never an accessor), a local / param binding whose scope encloses it and
	 * that lexically precedes it, or a field `fieldOk` proves physical.
	 *
	 * A one-step `<root>.<field>` path reads BOTH parts twice, so it needs both proofs: `root`
	 * accepted on its own terms, and `plainRead` — the resolution index proving the step itself
	 * resolves to a physical member rather than a property whose read runs a getter.
	 */
	private static function acceptedReceiver(
		subject: QueryNode, bindings: Array<{ name: String, scope: Span, declEnd: Int }>, fieldOk: (String, Span) -> Bool,
		plainRead: QueryNode -> Bool, s: Seams
	): Bool {
		if (subject.kind == s.fieldAccessKind)
			return acceptedReceiver(subject.children[0], bindings, fieldOk, plainRead, s) && plainRead(subject);
		final name: Null<String> = subject.name;
		final span: Null<Span> = subject.span;
		if (name == null || span == null) return false;
		if (name == s.selfText) return true;
		final useName: String = name;
		final useSpan: Span = span;
		final bound: Bool = bindings.exists(
			b -> b.name == useName && b.scope.from <= useSpan.from && useSpan.to <= b.scope.to && b.declEnd <= useSpan.from
		);
		return bound || fieldOk(useName, useSpan);
	}

	/**
	 * The per-file predicate deciding whether a NON-local receiver named `name` at `span` is a
	 * field whose double read is a provable no-op: it must be a PHYSICAL `var` / `final`
	 * (`fieldDeclKinds`) with no read accessor, declared directly by the type declaration that
	 * lexically encloses the use.
	 *
	 * A Haxe field cannot be redeclared by a subtype, and property accessors resolve from the
	 * STATIC type — so a plain field stays plain at every use of the declaring type. That, and only
	 * that, is what makes `if (f != null) f.m()` (two reads) and `f?.m()` (one) the same
	 * observation. Everything unproven refuses: a get-accessor property (`(get, …)` / `dynamic`,
	 * whose read RUNS code), a member of any other kind (a method value), a name the enclosing type
	 * does not itself declare (an inherited member, a static import, an out-of-scope local — none of
	 * which this proof can see), an EXTERN host (a foreign slot whose read may run host code), and a
	 * grammar with no accessor information at all (`TypeInfoProvider` absent — every property would
	 * then read as plain) or no extern modifier to name (`readSeams` empties `fieldDeclKinds`).
	 *
	 * Coverage is deliberately the enclosing type's OWN members. A resolution index that can prove
	 * the same facts about an INHERITED member widens this predicate without changing any caller —
	 * but the extern gate MUST move with it: `collectTypeScopes` reads only this file, so an
	 * inherited field whose declaring type is an `extern` class in another module would pass a gate
	 * that never saw it.
	 */
	private static function fieldProver(tree: QueryNode, source: String, plugin: GrammarPlugin, s: Seams): (String, Span) -> Bool {
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		if (provider == null || s.fieldDeclKinds.length == 0) return (_, _) -> false;
		final accessors: Map<Int, Bool> = provider.propertyAccessors(source);
		final scopes: Array<TypeScope> = [];
		collectTypeScopes(tree, false, s, scopes);
		return (name, span) -> {
			final host: Null<TypeScope> = innermostScope(scopes, span);
			return host != null && !host.isExtern && declaresPlainField(host.host, name, accessors, s);
		};
	}

	/** The innermost type declaration whose span contains `span`, or null when `span` sits outside every type. */
	private static function innermostScope(scopes: Array<TypeScope>, span: Span): Null<TypeScope> {
		var best: Null<TypeScope> = null;
		for (t in scopes) if (t.span.from <= span.from && span.to <= t.span.to && (best == null || t.span.from >= best.span.from)) best = t;
		return best;
	}

	/**
	 * Every type declaration under `node`, with the span it occupies and whether an extern
	 * modifier precedes it. `pendingExtern` carries an `extern` keyword forward across the
	 * modifier / metadata siblings that may sit between it and the declaration it marks — and
	 * into nested regions, since over-attaching it only ever REFUSES more.
	 */
	private static function collectTypeScopes(node: QueryNode, pendingExtern: Bool, s: Seams, out: Array<TypeScope>): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		var marked: Bool = pendingExtern;
		for (child in node.children) {
			if (child.kind == s.externKind) {
				marked = true;
				continue;
			}
			final decl: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(child);
			if (decl != null) {
				out.push({ span: decl.fullSpan, host: decl.nameNode, isExtern: marked });
				marked = false;
			}
			collectTypeScopes(child, marked, s, out);
		}
	}

	/**
	 * Whether `host` declares `name` as a physical field with no read accessor. A member of that
	 * name whose kind is not a field kind, or that carries a getter, REFUSES outright rather than
	 * being ignored — two same-named members cannot both be the receiver, so a single unproven
	 * declaration is enough to lose the proof.
	 */
	private static function declaresPlainField(host: QueryNode, name: String, accessors: Map<Int, Bool>, s: Seams): Bool {
		var proven: Bool = false;
		var refused: Bool = false;
		RefactorSupport.eachMemberHost(host, memberHost -> {
			for (child in memberHost.children) if (child.name == name && RefactorSupport.isMemberDeclKind(child.kind)) {
				final span: Null<Span> = child.span;
				if (span == null || !s.fieldDeclKinds.contains(child.kind) || accessors[span.from] == true)
					refused = true;
				else
					proven = true;
			}
		});
		return proven && !refused;
	}

	/**
	 * Walk `node`, tracking the innermost enclosing scope, recording every local
	 * declaration (`localDeclKinds`) and parameter (`paramKinds`) with the span of
	 * its enclosing scope. A reification subtree (`opaqueKinds`) is skipped wholesale.
	 */
	private static function collectBindings(
		node: QueryNode, enclosingScope: Null<QueryNode>, s: Seams, out: Array<{ name: String, scope: Span, declEnd: Int }>
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if (s.localDeclKinds.contains(node.kind) || s.paramKinds.contains(node.kind)) {
			final name: Null<String> = node.name;
			final declSpan: Null<Span> = node.span;
			final scope: Null<Span> = enclosingScope != null ? enclosingScope.span : null;
			if (name != null && declSpan != null && scope != null) out.push({ name: name, scope: scope, declEnd: declSpan.to });
		}
		final childScope: Null<QueryNode> = s.scopeKinds.contains(node.kind) ? node : enclosingScope;
		for (c in node.children) collectBindings(c, childScope, s, out);
	}

	/** The guard SUBJECT of a `x != null` / `null != x` guard condition, or null when `cond` is not that shape. */
	private static function guardOperand(cond: QueryNode, s: Seams): Null<QueryNode> {
		final c: QueryNode = RefactorSupport.unwrapParens(cond, s.parenKind);
		return c.kind == s.notEqKind && c.children.length == COMPARISON_CHILD_COUNT ? subjectOperand(c, s) : null;
	}

	/**
	 * The lone expression statement of a then-branch that is exactly one call
	 * statement — a bare `x.m();` or a braced block wrapping only that — else null.
	 */
	private static function singleCallStatement(body: QueryNode, s: Seams): Null<QueryNode> {
		final stmt: Null<QueryNode> = soleExprStatement(body, s);
		return stmt != null && stmt.children[0].kind == s.callKind ? stmt : null;
	}

	/**
	 * The lone single-expression statement of a then-branch that is exactly one statement — a
	 * bare `x.m();` / `r = x.m();` or a braced block wrapping only that — else null.
	 */
	private static function soleExprStatement(body: QueryNode, s: Seams): Null<QueryNode> {
		final stmt: Null<QueryNode> = if (body.kind == s.exprStmtKind)
			body;
		else if (body.kind == s.blockStmtKind && body.children.length == 1 && body.children[0].kind == s.exprStmtKind)
			body.children[0];
		else
			null;
		return stmt != null && stmt.children.length == 1 ? stmt : null;
	}

	/** The root identifier a guard subject is rooted at — the subject itself when it IS one, else the path's receiver. */
	private static function subjectRoot(subject: QueryNode, s: Seams): QueryNode {
		return subject.kind == s.fieldAccessKind ? subject.children[0] : subject;
	}

	/**
	 * Whether two nodes denote the same guard subject: two identifiers carrying one source name,
	 * or two one-step field accesses agreeing in both the field name and the root identifier.
	 */
	private static function sameSubject(a: QueryNode, b: QueryNode, s: Seams): Bool {
		final an: Null<String> = a.name;
		final bn: Null<String> = b.name;
		if (a.kind != b.kind || an == null || bn == null || an != bn) return false;
		if (a.kind == s.identKind) return true;
		return a.kind == s.fieldAccessKind && a.children.length == 1 && b.children.length == 1
			&& sameSubject(a.children[0], b.children[0], s);
	}


	/**
	 * Analyse an `if` condition for a null guard on a guard subject, returning the
	 * guarded operand and the surviving REMAINING condition (null for a sole guard):
	 *
	 * - `x != null` / `null != x` — the sole condition, `rest` is null;
	 * - `C && ... && x != null` — the guard is the LAST conjunct, so it is evaluated
	 *   last and no later conjunct can depend on `x` being non-null (`if (x != null &&
	 *   x.len > 0) …` is thus NOT matched); `rest` is the preceding `C && ...`, kept
	 *   verbatim by the fix as the surviving `if` condition.
	 *
	 * Any other shape (a guard that is not the last conjunct, a top-level `||`, …)
	 * returns null.
	 */
	private static function guardCondition(cond: QueryNode, s: Seams): Null<{ operand: QueryNode, rest: Null<QueryNode> }> {
		final sole: Null<QueryNode> = guardOperand(cond, s);
		if (sole != null) return { operand: sole, rest: null };
		final andKind: Null<String> = s.andKind;
		if (andKind == null) return null;
		final c: QueryNode = RefactorSupport.unwrapParens(cond, s.parenKind);
		if (c.kind != andKind || c.children.length != AND_CHILD_COUNT) return null;
		final operand: Null<QueryNode> = guardOperand(c.children[1], s);
		return operand == null ? null : { operand: operand, rest: c.children[0] };
	}


	/**
	 * Whether the guard subject appears in `node`'s subtree anywhere OTHER than at the chain
	 * root `root`. The rewrite narrows nothing after the `?.`, so any other occurrence — a call
	 * argument (`x.m(x)`), an intermediate-chain argument (`x.a(x).b()`), an index
	 * (`x.arr[x]`) — stays typed `Null<T>` and breaks `@:nullSafety(Strict)`; such a guard is
	 * left unflagged. A qualified subject rooted at a LOCAL is matched as a whole, so its bare
	 * root elsewhere in the body (`x.f?.m(x)`) is fine — the guard never narrowed it. An opaque
	 * reification subtree counts as a possible mention (conservative).
	 */
	private static function mentionsOutsideRoot(node: QueryNode, root: QueryNode, subject: QueryNode, s: Seams): Bool {
		if (s.opaqueKinds.contains(node.kind)) return true;
		if (node != root && denotesSubject(node, subject, s)) return true;
		return node.children.exists(c -> mentionsOutsideRoot(c, root, subject, s));
	}

	/**
	 * Whether `node` denotes the same value as the guard subject for the mention scan — a WIDER
	 * question than `sameSubject`, which the rewrite side must keep tight.
	 *
	 * A member of the ENCLOSING object has two spellings, `f` and `this.f`, and one null guard
	 * narrows both. Matching only the written shape would leave the other spelling un-narrowed
	 * after the rewrite (`if (this.f != null) this.f.use(f);` → `this.f?.use(f);`, where the
	 * argument `f` is back to `Null<T>`), so the two spellings match here. A bare identifier
	 * that is really a LOCAL matches a same-named `this.` member it has nothing to do with —
	 * conservative in the refusing direction, which is the safe one for this caller.
	 */
	private static function denotesSubject(node: QueryNode, subject: QueryNode, s: Seams): Bool {
		if (sameSubject(node, subject, s)) return true;
		final name: Null<String> = selfMemberName(node, s);
		return name != null && name == selfMemberName(subject, s);
	}

	/** The member name `node` reads off the enclosing object — a bare identifier, or the field of a `this.<field>` path — else null. */
	private static function selfMemberName(node: QueryNode, s: Seams): Null<String> {
		if (node.kind == s.identKind) return node.name == s.selfText ? null : node.name;
		return node.kind == s.fieldAccessKind && node.children.length == 1 && node.children[0].kind == s.identKind
			&& node.children[0].name == s.selfText
			? node.name
			: null;
	}

}

/** The `RefShape` kinds `PreferSafeNav` reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	var ifKinds: Array<String>;
	var notEqKind: String;
	var nullKind: String;
	var identKind: String;
	var callKind: String;
	var fieldAccessKind: String;
	var exprStmtKind: String;
	var blockStmtKind: String;
	var parenKind: Null<String>;
	var scopeKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var localDeclKinds: Array<String>;
	var paramKinds: Array<String>;
	var andKind: Null<String>;
	var ternaryKind: Null<String>;
	var eqKind: Null<String>;
	var chainKinds: Array<String>;
	var selfText: Null<String>;
	var assignKind: Null<String>;

	/** The member kinds that project a PHYSICAL field (Haxe `VarMember` / `FinalMember`) — the field-receiver proof's whitelist. */
	var fieldDeclKinds: Array<String>;

	/** The extern-modifier node kind, a preceding sibling of the type it marks — an extern host refuses the field-receiver proof. */
	var externKind: Null<String>;

	/**
	 * The STATEMENT-LIST kinds (`ControlFlowSupport.blockKinds`) whose direct children the
	 * assignment arm may pair. A conditional-compilation region is deliberately absent: its
	 * branches project as FLATTENED siblings, so pairing under it would fold a declaration in
	 * one `#if` branch into a guard in another. EMPTY when the grammar supplies no
	 * `ControlFlowSupport` — which switches the assignment arm alone off, exactly as an unset
	 * `ternaryKind` switches off the ternary arm.
	 */
	var blockKinds: Array<String>;
}

/**
 * A matched guard: the null-checked identifier, the region the rewrite keeps (`stmt` — the
 * body statement of an `if` arm, the guarded branch of a ternary arm), and the chain-root
 * identifier inside it. `restCond` is the surviving `if` condition, always null on the ternary arm.
 */
private typedef Candidate = {
	var condIdent: QueryNode;
	var stmt: QueryNode;
	var rootIdent: QueryNode;
	var restCond: Null<QueryNode>;
}

/**
 * A matched ASSIGNMENT-arm guard: the null-checked identifier, the guarding `if` statement the
 * fold deletes, the assigned right-hand side and its chain-root identifier, and the `null`
 * literal of the declaration the right-hand side folds into.
 */
private typedef AssignGuard = {
	var condIdent: QueryNode;
	var ifNode: QueryNode;
	var rhs: QueryNode;
	var rootIdent: QueryNode;
	var nullLiteral: QueryNode;
}

/** One type declaration's lexical extent: the span it covers, the node hosting its members, and whether `extern` marks it. */
private typedef TypeScope = {
	var span: Span;
	var host: QueryNode;
	var isExtern: Bool;
}

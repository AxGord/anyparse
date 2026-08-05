package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

/**
 * Flags a null guard that safe navigation (`?.`) replaces. Two arms:
 *
 * - STATEMENT — `if (x != null) x.m(...)` (and the braced `if (x != null) { x.m(...); }`,
 *   plus the reversed `if (null != x) …`) collapses to `x?.m(...);`. A CONJUNCTION guard
 *   `if (C && ... && x != null) x.m(...)` drops the null-check, keeping the rest:
 *   `if (C && ...) x?.m(...);`.
 * - TERNARY — `x == null ? null : x.m(...)` and its dual `x != null ? x.m(...) : null`
 *   (either polarity, the `null` operand on either side of the comparison) collapse to
 *   `x?.m(...)`, the EXPRESSION form of the same guard. `?.` short-circuits the whole
 *   receiver chain, so a multi-step body (`x.map(f).join(',')`, `x.arr[0].c`) collapses
 *   in one step exactly like the statement arm.
 *
 * `Severity.Info` (a modernization cleanup), with an autofix.
 *
 * ## Soundness — a LOCAL / PARAM / `this` receiver, a CALL body, no else, `x` only as the root
 *
 * `if (field != null) field.m()` reads `field` twice, `field?.m()` once — so a
 * receiver backed by a property getter would change semantics. The guard is
 * flagged ONLY when the guarded identifier resolves to a local declaration
 * (`localDeclKinds`) or a parameter (`paramKinds`) whose scope encloses it: a
 * local can carry no accessor, so its double read is a provable no-op. A bare
 * field reference (implicit `this.`), a `this.x` / qualified receiver (whose
 * guard operand is not a plain identifier) and every field are left alone. The
 * surviving-condition operands (the kept conjuncts) are read the same number of
 * times before and after, so THEY may be fields.
 *
 * The self reference (`selfReferenceText`, projected as a plain identifier named
 * `this`) is accepted alongside a local / param: it is a keyword denoting the current
 * object — in an ABSTRACT, the underlying value, which is where a nullable `this`
 * actually occurs — and can carry no accessor, so reading it twice or once is the same
 * observation. That is what unlocks the abstract idiom
 * `@:to function toString() return this == null ? null : this.map(f).join(',');`.
 *
 * The then-branch must be exactly ONE expression statement whose expression is a
 * CALL that is a plain chain rooted at the guarded identifier (`x.m(...)` /
 * `x.a.b(...)` — see `chainAccess` below), so:
 *
 * - a multi-statement block is NOT flagged (the user groups those under one `if`
 *   deliberately);
 * - an assignment l-value (`x.f = v`) is NOT flagged — `x?.f = v` does not
 *   compile;
 * - a body already using `?.` on the root (`x?.m()`) is NOT flagged — its first
 *   access projects as `nullSafeAccessKind`, not `fieldAccessKind` (the dead- /
 *   unnecessary-safe-nav checks' territory);
 * - an `else` branch makes the guard a real two-way choice — NOT flagged;
 * - the guarded identifier appearing in the body anywhere but the chain root
 *   (`x.m(x)`, `x.a(x).b()`, `x.arr[x]`) is NOT flagged — after `x?.` it stays
 *   typed `Null<T>`, breaking `@:nullSafety(Strict)`.
 *
 * ## Conjunction — the null-check must be the LAST conjunct
 *
 * Conjuncts evaluate left-to-right, so a conjunct AFTER `x != null` may rely on
 * `x` being non-null (`if (x != null && x.len > 0) …`). Only a null-check that is
 * the LAST conjunct is dropped, leaving the preceding conjuncts as the surviving
 * `if` condition (kept verbatim, so a comment inside them is preserved).
 *
 * ## The kept region must BE the chain — `chainAccess`, shared by both arms
 *
 * The rewrite replaces the whole guard with the kept region, so that region has to be the
 * receiver chain itself and nothing more. `chainAccess` therefore descends the `children[0]`
 * receiver spine through CHAIN steps only (`chainKinds` — `fieldAccessKind`, `callKind`,
 * `indexAccessKind`), and the junction off the guarded identifier must be a plain `.`
 * (`fieldAccessKind`), so an index root (`x[0].f`) and an already-safe `x?.f` root are left
 * alone. `?.` short-circuits every chain step after it, so an index or a call MID-chain
 * (`x.arr[0].c`, `x.map(f).join(',')`) collapses fine — but a `cast`, a parenthesis, an
 * ascription or an operator on the spine does NOT: `(cast x.a).m()` would become
 * `(cast x?.a).m()`, which dereferences null, and `x == null ? null : x.f + 1` would become
 * `x?.f + 1`, which adds to a `Null<T>`. A spine node outside `chainKinds` ends the descent
 * with no match, which refuses all of those by construction.
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
 * (conjunction) — with the FIRST dot off the guarded identifier turned into `?.`
 * (`if (x != null) x.a.b();` → `x?.a.b();`, `x == null ? null : x.a.b()` → `x?.a.b()`):
 * only the guard being removed is encoded, inner nullables stay the author's concern.
 * A comment inside a DROPPED part of the removed region would be lost, so such a guard
 * is left unflagged; a comment between the receiver and its dot would SWALLOW the inserted
 * `?`, so that one leaves the guard reported but unfixed.
 *
 * ## Grammar-agnostic
 *
 * Driven by `ifStatementKinds`, `notEqKind`, `nullLiteralKind`, `callKind`,
 * `fieldAccessKind`, `exprStatementKind`, `blockStmtKind` (any unset → no-op),
 * plus `logicalAndKind` for the conjunction form, `ternaryKind` for the ternary arm
 * (unset → that arm alone is off) with `eqKind` adding its `x == null ? null : …`
 * polarity, `indexAccessKind` for an index step on a chain, `selfReferenceText` for the
 * `this` receiver, `localDeclKinds` / `paramKinds` / `scopeKinds` for the binding
 * resolution, `parenKind` to unwrap a parenthesized condition or ternary branch, and
 * `opaqueKinds` to skip reification subtrees.
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

	public function new() {}

	public function id(): String {
		return 'prefer-safe-nav';
	}

	public function description(): String {
		return 'a null guard (if (x != null) x.m(), x == null ? null : x.m()) replaceable with safe navigation (x?.m())';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin.refShape());
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final bindings: Array<{ name: String, scope: Span, declEnd: Int }> = [];
			collectBindings(tree, null, seams, bindings);
			walk(tree, violations, entry.file, entry.source, bindings, seams);
		}
		return violations;
	}

	/** Rewrite each flagged guard to `<root>?.<rest>`, replacing the whole `if` statement / ternary. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin.refShape());
		if (seams == null) return [];
		final s: Seams = seams;
		final ternaryKind: Null<String> = s.ternaryKind;
		final spanIndexKinds: Array<String> = ternaryKind == null ? s.ifKinds : s.ifKinds.concat([ternaryKind]);
		final edits: Array<{ span: Span, text: String }> =
			CheckScan.applyBySpan(plugin, source, violations, spanIndexKinds, (node, span) -> {
				final m: Null<Candidate> = candidate(node, source, s);
				if (m == null) return null;
				final stmtSpan: Null<Span> = m.stmt.span;
				final rootSpan: Null<Span> = m.rootIdent.span;
				if (stmtSpan == null || rootSpan == null) return null;
				final dotPos: Int = source.indexOf('.', rootSpan.to);
				if (dotPos < 0 || dotPos >= stmtSpan.to) return null;
				// A comment between the receiver and its dot would swallow the inserted `?`.
				if (CheckScan.hasCommentMarker(source, rootSpan.to, dotPos)) return null;
				final prefix: String = source.substring(stmtSpan.from, dotPos);
				final suffix: String = source.substring(dotPos + 1, stmtSpan.to);
				final body: String = '$prefix?.$suffix';
				final rest: Null<QueryNode> = m.restCond;
				final restSpan: Null<Span> = rest?.span;
				if (rest != null && restSpan == null) return null;
				final text: String = restSpan != null
					? 'if (${StringTools.trim(source.substring(restSpan.from, restSpan.to))}) $body'
					: body;
				return { span: span, text: text };
			});
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Bundle the required + optional `RefShape` kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(shape: RefShape): Null<Seams> {
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
			selfText: shape.selfReferenceText
		};
	}

	/** Walk `node`, flagging each guard that `candidate` accepts and whose operand binds to a local / param / `this`. */
	private static function walk(
		node: QueryNode, out: Array<Violation>, file: String, source: String, bindings: Array<{ name: String, scope: Span, declEnd: Int }>,
		s: Seams
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		final m: Null<Candidate> = candidate(node, source, s);
		if (m != null && acceptedReceiver(m.condIdent, bindings, s)) {
			final span: Null<Span> = node.span;
			if (span != null) out.push({
				file: file,
				span: span,
				rule: 'prefer-safe-nav',
				severity: Severity.Info,
				message: 'this null guard can be safe navigation (?.)'
			});
		}
		for (c in node.children) walk(c, out, file, source, bindings, s);
	}

	/** The candidate `node` yields — the `if`-statement guard or the ternary guard, whichever arm its kind selects. */
	private static function candidate(node: QueryNode, source: String, s: Seams): Null<Candidate> {
		if (s.ifKinds.contains(node.kind)) return match(node, source, s);
		return node.kind == s.ternaryKind ? matchTernary(node, source, s) : null;
	}

	/**
	 * If `ternary` is a null guard whose guarded branch is exactly a receiver chain rooted
	 * at the guarded identifier — `x == null ? null : x.chain(...)` or its dual
	 * `x != null ? x.chain(...) : null` — return that guard; else null. The other branch
	 * must be the bare `null` literal, the chain must reach the identifier through plain
	 * `.` / call / index steps only (so `x.f + 1` is refused), the identifier must not
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
		final condIdent: Null<QueryNode> = plainOperand(cond, s);
		if (condIdent == null) return null;
		final branch: QueryNode = RefactorSupport.unwrapParens(ternary.children[elseIsGuarded ? 2 : 1], s.parenKind);
		final fallback: QueryNode = RefactorSupport.unwrapParens(ternary.children[elseIsGuarded ? 1 : 2], s.parenKind);
		if (fallback.kind != s.nullKind) return null;
		final access: Null<QueryNode> = chainAccess(branch, s);
		if (access == null || !sameName(condIdent, access.children[0])) return null;
		final guardName: Null<String> = condIdent.name;
		if (guardName == null) return null;
		if (mentionsOutsideRoot(branch, access.children[0], guardName, s)) return null;
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

	/** The plain-identifier operand of a `<ident> <op> null` / `null <op> <ident>` comparison, or null for any other shape. */
	private static function plainOperand(cond: QueryNode, s: Seams): Null<QueryNode> {
		final a: QueryNode = cond.children[0];
		final b: QueryNode = cond.children[1];
		return if (a.kind == s.nullKind && b.kind == s.identKind)
			b;
		else if (b.kind == s.nullKind && a.kind == s.identKind)
			a;
		else
			null;
	}

	/**
	 * Descend `node`'s receiver spine through CHAIN steps only (`chainKinds` — field access,
	 * call, index) until the receiver is a plain identifier, returning the node that directly
	 * holds it, and only when that node is a plain `.` field access. Null when `node` is not a
	 * chain at all (`x.f + 1`), when the spine bottoms out on something else, or when the
	 * junction off the identifier is an index / already-safe access.
	 */
	private static function chainAccess(node: QueryNode, s: Seams): Null<QueryNode> {
		var n: QueryNode = node;
		while (s.chainKinds.contains(n.kind) && n.children.length > 0) {
			if (n.children[0].kind == s.identKind) return n.kind == s.fieldAccessKind ? n : null;
			n = n.children[0];
		}
		return null;
	}

	/**
	 * If `ifNode` is a no-`else` guard whose then-branch is a single call statement
	 * rooted at a plain identifier `x` reached by a plain `.`, return the guard
	 * operand, the body statement, the chain-root identifier and the surviving
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
		final access: Null<QueryNode> = firstAccess(stmt, s);
		if (access == null) return null;
		final root: QueryNode = access.children[0];
		if (!sameName(condIdent, root)) return null;
		final guardName: Null<String> = condIdent.name;
		if (guardName == null) return null;
		if (mentionsOutsideRoot(stmt.children[0], root, guardName, s)) return null;
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
	 * Whether `ident` is a receiver whose double read is provably free: the self reference
	 * (a keyword, never an accessor), or a local / param binding whose scope encloses it and
	 * that lexically precedes it.
	 */
	private static function acceptedReceiver(
		ident: QueryNode, bindings: Array<{ name: String, scope: Span, declEnd: Int }>, s: Seams
	): Bool {
		final name: Null<String> = ident.name;
		final span: Null<Span> = ident.span;
		if (name == null || span == null) return false;
		if (name == s.selfText) return true;
		final useName: String = name;
		final useSpan: Span = span;
		return bindings.exists(
			b -> b.name == useName && b.scope.from <= useSpan.from && useSpan.to <= b.scope.to && b.declEnd <= useSpan.from
		);
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

	/** The plain-identifier operand of a `x != null` / `null != x` guard condition, or null when `cond` is not that shape. */
	private static function guardOperand(cond: QueryNode, s: Seams): Null<QueryNode> {
		final c: QueryNode = RefactorSupport.unwrapParens(cond, s.parenKind);
		return c.kind == s.notEqKind && c.children.length == COMPARISON_CHILD_COUNT ? plainOperand(c, s) : null;
	}

	/**
	 * The lone expression statement of a then-branch that is exactly one call
	 * statement — a bare `x.m();` or a braced block wrapping only that — else null.
	 */
	private static function singleCallStatement(body: QueryNode, s: Seams): Null<QueryNode> {
		final stmt: Null<QueryNode> = if (body.kind == s.exprStmtKind)
			body;
		else if (body.kind == s.blockStmtKind && body.children.length == 1 && body.children[0].kind == s.exprStmtKind)
			body.children[0];
		else
			null;
		if (stmt == null) return null;
		final expr: QueryNode = stmt;
		return expr.children.length == 1 && expr.children[0].kind == s.callKind ? expr : null;
	}

	/** The FIRST access off the body call's chain root when it is a plain `.` field access — `chainAccess` on the call. */
	private static function firstAccess(stmt: QueryNode, s: Seams): Null<QueryNode> {
		return chainAccess(stmt.children[0], s);
	}

	/** Whether two identifier nodes carry the same source name. */
	private static function sameName(a: QueryNode, b: QueryNode): Bool {
		final an: Null<String> = a.name;
		final bn: Null<String> = b.name;
		return an != null && bn != null && an == bn;
	}


	/**
	 * Analyse an `if` condition for a null guard on a plain identifier, returning the
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
	 * Whether the guarded identifier `name` appears in `node`'s subtree anywhere OTHER
	 * than at the chain root `root`. The rewrite narrows nothing after the `?.`, so any
	 * other `x` — a call argument (`x.m(x)`), an intermediate-chain argument
	 * (`x.a(x).b()`), an index (`x.arr[x]`) — stays typed `Null<T>` and breaks
	 * `@:nullSafety(Strict)`; such a guard is left unflagged. An opaque reification
	 * subtree counts as a possible mention (conservative).
	 */
	private static function mentionsOutsideRoot(node: QueryNode, root: QueryNode, name: String, s: Seams): Bool {
		if (s.opaqueKinds.contains(node.kind)) return true;
		if (node != root && node.kind == s.identKind && node.name == name) return true;
		return node.children.exists(c -> mentionsOutsideRoot(c, root, name, s));
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

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
 * Flags a single-statement null guard that safe navigation (`?.`) replaces —
 * `if (x != null) x.m(...)` (and the braced `if (x != null) { x.m(...); }`, plus
 * the reversed `if (null != x) …`) collapses to `x?.m(...);`. A CONJUNCTION guard
 * `if (C && ... && x != null) x.m(...)` drops the null-check, keeping the rest:
 * `if (C && ...) x?.m(...);`. `Severity.Info` (a modernization cleanup), with an autofix.
 *
 * ## Soundness — a LOCAL / PARAM receiver, a CALL body, no else, `x` only as the root
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
 * The then-branch must be exactly ONE expression statement whose expression is a
 * CALL rooted at the guarded identifier (`x.m(...)` / `x.a.b(...)`), so:
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
 * ## Autofix
 *
 * The whole `if` statement is replaced by the body statement (sole guard) or by
 * `if (<surviving condition>) <body>` (conjunction), with the FIRST dot off the
 * guarded identifier turned into `?.` (`if (x != null) x.a.b();` → `x?.a.b();`):
 * only the guard being removed is encoded, inner nullables stay the author's
 * concern. A comment inside a DROPPED part of the removed `if` region would be
 * lost, so such a guard is left unflagged.
 *
 * ## Grammar-agnostic
 *
 * Driven by `ifStatementKinds`, `notEqKind`, `nullLiteralKind`, `callKind`,
 * `fieldAccessKind`, `exprStatementKind`, `blockStmtKind` (any unset → no-op),
 * plus `logicalAndKind` for the conjunction form, `localDeclKinds` / `paramKinds`
 * / `scopeKinds` for the binding resolution, `parenKind` to unwrap a
 * parenthesized condition, and `opaqueKinds` to skip reification subtrees.
 */
@:nullSafety(Strict)
final class PreferSafeNav implements Check {

	/** An `if` with no `else` has exactly [condition, then-branch] children. */
	private static inline final IF_NO_ELSE_CHILD_COUNT: Int = 2;

	/** A binary comparison node has exactly [left, right] children. */
	private static inline final COMPARISON_CHILD_COUNT: Int = 2;

	/** A logical-AND node has exactly [preceding-conjuncts, last-conjunct] children. */
	private static inline final AND_CHILD_COUNT: Int = 2;

	public function new() {}

	public function id(): String {
		return 'prefer-safe-nav';
	}

	public function description(): String {
		return 'a single-statement null guard (if (x != null) x.m()) replaceable with safe navigation (x?.m())';
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

	/** Rewrite each flagged guard to `<root>?.<rest>;`, replacing the whole `if` statement. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin.refShape());
		if (seams == null) return [];
		final edits: Array<{ span: Span, text: String }> =
			CheckScan.applyBySpan(plugin, source, violations, seams.ifKinds, (node, span) -> {
				final m: Null<Candidate> = match(node, source, seams);
				if (m == null) return null;
				final stmtSpan: Null<Span> = m.stmt.span;
				final rootSpan: Null<Span> = m.rootIdent.span;
				if (stmtSpan == null || rootSpan == null) return null;
				final dotPos: Int = source.indexOf('.', rootSpan.to);
				if (dotPos < 0 || dotPos >= stmtSpan.to) return null;
				final prefix: String = source.substring(stmtSpan.from, dotPos);
				final suffix: String = source.substring(dotPos + 1, stmtSpan.to);
				final body: String = '$prefix?.$suffix';
				final rest: Null<QueryNode> = m.restCond;
				final restSpan: Null<Span> = rest != null ? rest.span : null;
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
		return blockStmtKind == null ? null : {
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
			andKind: shape.logicalAndKind
		};
	}

	/** Walk `node`, flagging each `if` guard that `match` accepts and whose operand binds to a local / param. */
	private static function walk(
		node: QueryNode, out: Array<Violation>, file: String, source: String, bindings: Array<{ name: String, scope: Span, declEnd: Int }>,
		s: Seams
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if (s.ifKinds.contains(node.kind)) {
			final m: Null<Candidate> = match(node, source, s);
			if (m != null && bindsLocalOrParam(m.condIdent, bindings)) {
				final span: Null<Span> = node.span;
				if (span != null) out.push({
					file: file,
					span: span,
					rule: 'prefer-safe-nav',
					severity: Severity.Info,
					message: 'this null guard can be safe navigation (?.)'
				});
			}
		}
		for (c in node.children) walk(c, out, file, source, bindings, s);
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
			gapHasComment(source, ifSpan.from, restSpan.from) || gapHasComment(source, restSpan.to, stmtSpan.from);
		else
			gapHasComment(source, ifSpan.from, stmtSpan.from);
		final hasComment: Bool = headHasComment || gapHasComment(source, stmtSpan.to, ifSpan.to);
		return hasComment ? null : {
			condIdent: condIdent,
			stmt: stmt,
			rootIdent: root,
			restCond: rest
		};
	}

	/**
	 * Descend the `children[0]` receiver chain of `node` (`FieldAccess` / `Call` /
	 * index / safe-nav wrappers all carry the receiver there) until the receiver is
	 * a plain identifier, returning the node that directly holds it (the FIRST access
	 * off the root). Null when the chain bottoms out without one.
	 */
	private static function chainRoot(node: QueryNode, identKind: String): Null<QueryNode> {
		if (node.children.length < 1) return null;
		final recv: QueryNode = node.children[0];
		return recv.kind == identKind ? node : chainRoot(recv, identKind);
	}

	/** Whether `ident` resolves to a local / param binding whose scope encloses it and that lexically precedes it. */
	private static function bindsLocalOrParam(ident: QueryNode, bindings: Array<{ name: String, scope: Span, declEnd: Int }>): Bool {
		final name: Null<String> = ident.name;
		final span: Null<Span> = ident.span;
		if (name == null || span == null) return false;
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

	/** Whether the `[from, to)` gap holds a `//` or `/*` comment opener (the guard region we would drop). */
	private static function gapHasComment(source: String, from: Int, to: Int): Bool {
		if (from >= to) return false;
		final gap: String = source.substring(from, to);
		return gap.indexOf('//') != -1 || gap.indexOf('/*') != -1;
	}


	/** The plain-identifier operand of a `x != null` / `null != x` guard condition, or null when `cond` is not that shape. */
	private static function guardOperand(cond: QueryNode, s: Seams): Null<QueryNode> {
		final c: QueryNode = RefactorSupport.unwrapParens(cond, s.parenKind);
		if (c.kind != s.notEqKind || c.children.length != COMPARISON_CHILD_COUNT) return null;
		final a: QueryNode = c.children[0];
		final b: QueryNode = c.children[1];
		return if (a.kind == s.nullKind && b.kind == s.identKind)
			b;
		else if (b.kind == s.nullKind && a.kind == s.identKind)
			a;
		else
			null;
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

	/** The FIRST access off the call's chain root when it is a plain `.` field access (`fieldAccessKind`); else null. */
	private static function firstAccess(stmt: QueryNode, s: Seams): Null<QueryNode> {
		final call: QueryNode = stmt.children[0];
		if (call.children.length < 1) return null;
		final access: Null<QueryNode> = chainRoot(call.children[0], s.identKind);
		return access != null && access.kind == s.fieldAccessKind ? access : null;
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
}

/** A matched guard: the null-checked identifier, its body statement, and the chain-root identifier in the body. */
private typedef Candidate = {
	var condIdent: QueryNode;
	var stmt: QueryNode;
	var rootIdent: QueryNode;
	var restCond: Null<QueryNode>;
}

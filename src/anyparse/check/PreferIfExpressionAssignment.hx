package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.IfExpressionChain.IfChain;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags an `if / else if / … / else` CHAIN whose EVERY branch assigns the SAME l-value
 * with a plain `=`, collapsing the whole chain to one assignment of an if-expression:
 *
 * ```haxe
 * if (cond)   button.x = a;
 * else if (d) button.x = b;
 * else        button.x = c;
 * // ->
 * button.x = if (cond) a else if (d) b else c;
 * ```
 *
 * Purely structural (no type information), so it holds without a type-checker. `Info` --
 * the code is correct, this is a readability simplification.
 *
 * ## Boundary with `prefer-ternary-assignment`
 *
 * The two are DISJOINT by branch count. `prefer-ternary-assignment` handles the 2-branch
 * `if`/`else` (its `else` is NOT an `if`) and emits a ternary; a chain would give ugly
 * nested ternaries, so it leaves one alone. This rule handles ONLY the chain (≥1
 * `else if`, terminating in a plain `else`) -- an if-expression collapses it cleanly. A
 * given `if` matches at most one of the two.
 *
 * ## What is flagged
 *
 * A chain HEAD (an `if` that is not itself the `else if` link of another) whose:
 *
 * - else-nesting terminates in a plain `else` (a chain with no final `else` yields no
 *   value on the missing path and is skipped -- `IfExpressionChain.collect`);
 * - every branch AND the terminal is exactly ONE statement -- a bare `lhs = e;` or a
 *   braced `{ lhs = e; }` wrapping one (a multi-statement block is deliberately grouped);
 * - every statement is a PLAIN `=` assignment (`assignKind`). Compound operators are
 *   deliberately EXCLUDED: a short-circuit `??=` would change behaviour (its r-value, now
 *   holding the conditions, is skipped when the l-value is non-null, so the conditions
 *   stop being evaluated), and an ordinary compound (`+=`, …) whose branch values do not
 *   unify to one type (`s += anInt` vs `s += "text"`) compiles per-branch but not as one
 *   if-expression. Plain `=` flows the l-value's type into every branch, sidestepping both;
 * - all l-values are TEXTUALLY IDENTICAL (whitespace-normalized source).
 *
 * A comment inside a DROPPED region of the collapsed chain (a header keyword, the braces,
 * a non-head l-value) would be lost, so such a chain is left unflagged. Unlike the ternary
 * sibling NO null-narrowing guard is needed -- the collapsed `if (…)` conditions are
 * verbatim, so each branch keeps exactly the narrowing it had (see `IfExpressionChain`).
 * The reported span is the whole head `if`.
 *
 * ## Autofix
 *
 * `fix` replaces the head `if` with `lhs op if (c1) rhs1 else if (c2) rhs2 … else rhsN;`.
 * The l-value and operator are copied verbatim from the HEAD branch, the conditions and
 * r-values from their spans, so the one surviving l-value evaluation (down from N textual
 * occurrences -- the safe direction) matches the original exactly. Needs
 * `ifStatementKinds`, `exprStatementKind`, `blockStmtKind` (any unset makes it a no-op).
 */
@:nullSafety(Strict)
final class PreferIfExpressionAssignment implements Check {

	/** A binary assignment node has exactly [l-value, r-value] children. */
	private static inline final ASSIGN_CHILD_COUNT: Int = 2;

	public function new() {}

	public function id(): String {
		return 'prefer-if-expression-assignment';
	}

	public function description(): String {
		return 'an if/else-if chain assigning the same l-value in every branch, collapsible to a single if-expression assignment';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin.refShape());
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final comments: Array<{ from: Int, to: Int, isLine: Bool }> = RefactorSupport.collectCommentTokens(entry.source);
			walk(tree, violations, entry.file, entry.source, comments, seams);
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin.refShape());
		if (seams == null) return [];
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = RefactorSupport.collectCommentTokens(source);
		final edits: Array<{ span: Span, text: String }> =
			CheckScan.applyBySpan(plugin, source, violations, seams.ifKinds, (node, span) -> {
				final m: Null<Match> = match(node, source, comments, seams);
				return m == null ? null : buildEdit(m, source, span);
			});
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Bundle the required `RefShape` kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(shape: RefShape): Null<Seams> {
		final ifKinds: Null<Array<String>> = shape.ifStatementKinds;
		if (ifKinds == null || ifKinds.length == 0) return null;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		if (exprStmtKind == null) return null;
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		if (blockStmtKind == null) return null;
		final assignKind: Null<String> = shape.assignKind;
		return assignKind == null ? null : {
			ifKinds: ifKinds,
			exprStmtKind: exprStmtKind,
			blockStmtKind: blockStmtKind,
			assignKind: assignKind
		};
	}

	/** Walk `node`, flagging each chain HEAD whose branches all assign the same l-value with the same operator. */
	private static function walk(
		node: QueryNode, out: Array<Violation>, file: String, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>,
		s: Seams, ?parent: QueryNode
	): Void {
		if (s.ifKinds.contains(node.kind) && !IfExpressionChain.isElseIfLink(node, parent, s.ifKinds)) {
			final m: Null<Match> = match(node, source, comments, s);
			if (m != null) {
				final span: Null<Span> = node.span;
				if (span != null) out.push({
					file: file,
					span: span,
					rule: 'prefer-if-expression-assignment',
					severity: Severity.Info,
					message: 'this if/else-if assignment chain can be a single if-expression assignment'
				});
			}
		}
		for (c in node.children) walk(c, out, file, source, comments, s, node);
	}

	/**
	 * If `head` is a chain of same-l-value / same-operator single-assignment branches and no
	 * comment sits in a dropped region, return the match parts; else null.
	 */
	private static function match(
		head: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams
	): Null<Match> {
		final chain: Null<IfChain> = IfExpressionChain.collect(head, s.ifKinds, s.blockStmtKind);
		if (chain == null) return null;
		final firstAssign: Null<QueryNode> = assignmentIn(chain.branches[0].stmt, s);
		if (firstAssign == null) return null;
		// Re-bind to a non-null local: narrowing does not reach the struct literal below.
		final headAssign: QueryNode = firstAssign;
		final opKind: String = headAssign.kind;
		final lhs: QueryNode = headAssign.children[0];
		final pairs: Array<{ cond: QueryNode, rhs: QueryNode }> = [];
		for (b in chain.branches) {
			final a: Null<QueryNode> = assignmentIn(b.stmt, s);
			if (a == null || a.kind != opKind || !IfExpressionChain.sameSource(a.children[0], lhs, source)) return null;
			pairs.push({ cond: b.cond, rhs: a.children[1] });
		}
		final term: Null<QueryNode> = assignmentIn(chain.terminal, s);
		if (term == null || term.kind != opKind || !IfExpressionChain.sameSource(term.children[0], lhs, source)) return null;
		final m: Match = { headAssign: headAssign, pairs: pairs, terminalRhs: term.children[1] };
		return droppedComment(head, m, comments) ? null : m;
	}

	/**
	 * The lone plain-`=` assignment (two children: l-value, r-value) that is `stmt` -- a
	 * bare `x = e;` expression statement wrapping one. Null when `stmt` is not a single
	 * plain assignment (a compound `+=` / `??=`, or an increment / decrement, is excluded).
	 */
	private static function assignmentIn(stmt: QueryNode, s: Seams): Null<QueryNode> {
		if (stmt.kind != s.exprStmtKind || stmt.children.length != 1) return null;
		final assign: QueryNode = stmt.children[0];
		return assign.kind == s.assignKind && assign.children.length == ASSIGN_CHILD_COUNT ? assign : null;
	}

	/** Build the `lhs op if (c1) rhs1 else if (c2) rhs2 … else rhsN;` edit replacing the whole head-`if` span. */
	private static function buildEdit(m: Match, source: String, span: Span): Null<{ span: Span, text: String }> {
		final headSpan: Null<Span> = m.headAssign.span;
		final headRhsSpan: Null<Span> = m.pairs[0].rhs.span;
		if (headSpan == null || headRhsSpan == null) return null;
		final prefix: String = source.substring(headSpan.from, headRhsSpan.from);
		final built: Array<{ cond: String, value: String }> = [];
		for (p in m.pairs) {
			final cond: Null<String> = slice(source, p.cond);
			final value: Null<String> = slice(source, p.rhs);
			if (cond == null || value == null) return null;
			built.push({ cond: cond, value: value });
		}
		final terminalValue: Null<String> = slice(source, m.terminalRhs);
		if (terminalValue == null) return null;
		return { span: span, text: IfExpressionChain.buildText(prefix, built, terminalValue) };
	}

	/** Whether a comment sits in a region the collapse drops (delegates to `IfExpressionChain` with the kept spans). */
	private static function droppedComment(head: QueryNode, m: Match, comments: Array<{ from: Int, to: Int, isLine: Bool }>): Bool {
		final headSpan: Null<Span> = head.span;
		final headAssignSpan: Null<Span> = m.headAssign.span;
		final headRhsSpan: Null<Span> = m.pairs[0].rhs.span;
		if (headSpan == null || headAssignSpan == null || headRhsSpan == null) return false;
		final kept: Array<Span> = [new Span(headAssignSpan.from, headRhsSpan.from)];
		for (p in m.pairs) {
			if (p.cond.span != null) kept.push((p.cond.span: Span));
			if (p.rhs.span != null) kept.push((p.rhs.span: Span));
		}
		if (m.terminalRhs.span != null) kept.push((m.terminalRhs.span: Span));
		return IfExpressionChain.droppedComment(headSpan, kept, comments);
	}

	/** The source text of `node`'s span, or null when it has none. */
	private static function slice(source: String, node: QueryNode): Null<String> {
		final span: Null<Span> = node.span;
		return span == null ? null : source.substring(span.from, span.to);
	}

}

/** The `RefShape` kinds `PreferIfExpressionAssignment` reads. */
private typedef Seams = {
	var ifKinds: Array<String>;
	var exprStmtKind: String;
	var blockStmtKind: String;
	var assignKind: String;
}

/** A matched assignment chain: the head assignment (for the prefix), the (condition, r-value) pairs, the terminal r-value. */
private typedef Match = {
	var headAssign: QueryNode;
	var pairs: Array<{ cond: QueryNode, rhs: QueryNode }>;
	var terminalRhs: QueryNode;
}

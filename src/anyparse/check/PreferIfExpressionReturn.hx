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
 * Flags an `if / else if / … / else` CHAIN whose EVERY branch is a valued `return`,
 * collapsing the whole chain to one `return` of an if-expression:
 *
 * ```haxe
 * if (cond)   return a;
 * else if (d) return b;
 * else        return c;
 * // ->
 * return if (cond) a else if (d) b else c;
 * ```
 *
 * Purely structural, so it holds without a type-checker. `Info` -- the code is correct,
 * this is a readability simplification. The `return` sibling of
 * `prefer-if-expression-assignment`; see it and `IfExpressionChain` for the chain shape,
 * the single-statement rule, the dropped-comment guard and why no null-narrowing guard is
 * needed.
 *
 * ## Boundary with `prefer-ternary-return`
 *
 * Disjoint. `prefer-ternary-return` collapses an `if (c) return a; return b;` (an
 * if/return followed by a fall-through return) to a ternary. This rule collapses ONLY an
 * explicit `if / else if / … / else` chain (≥1 `else if`, terminating in a plain `else`)
 * of `return`s, to an if-expression.
 *
 * ## What is flagged
 *
 * A chain HEAD whose else-nesting terminates in a plain `else`, every branch AND the
 * terminal is exactly ONE valued `return` statement (a bare `return;` -- a distinct
 * node kind -- disqualifies), and no comment sits in a dropped region. The reported span
 * is the whole head `if`.
 *
 * ## Autofix
 *
 * `fix` replaces the head `if` with `return if (c1) a else if (c2) b … else n;` -- the
 * `return ` prefix copied from the head, the conditions and returned values from their
 * spans. Needs `ifStatementKinds`, `returnStatementKind`, `blockStmtKind` (any unset
 * makes it a no-op).
 */
@:nullSafety(Strict)
final class PreferIfExpressionReturn implements Check {

	/** A valued `return` node has exactly one child: the returned expression. */
	private static inline final RETURN_VALUE_CHILD_COUNT: Int = 1;

	public function new() {}

	public function id(): String {
		return 'prefer-if-expression-return';
	}

	public function description(): String {
		return 'an if/else-if chain returning in every branch, collapsible to a single if-expression return';
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
		final returnKind: Null<String> = shape.returnStatementKind;
		if (returnKind == null) return null;
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		return blockStmtKind == null ? null : {
			ifKinds: ifKinds,
			returnKind: returnKind,
			blockStmtKind: blockStmtKind
		};
	}

	/** Walk `node`, flagging each chain HEAD whose branches all return a value. */
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
					rule: 'prefer-if-expression-return',
					severity: Severity.Info,
					message: 'this if/else-if return chain can be a single if-expression return'
				});
			}
		}
		for (c in node.children) walk(c, out, file, source, comments, s, node);
	}

	/**
	 * If `head` is a chain of single valued-`return` branches and no comment sits in a
	 * dropped region, return the match parts; else null.
	 */
	private static function match(
		head: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams
	): Null<Match> {
		final chain: Null<IfChain> = IfExpressionChain.collect(head, s.ifKinds, s.blockStmtKind);
		if (chain == null) return null;
		final pairs: Array<{ cond: QueryNode, value: QueryNode }> = [];
		for (b in chain.branches) {
			final v: Null<QueryNode> = returnValue(b.stmt, s);
			if (v == null) return null;
			pairs.push({ cond: b.cond, value: v });
		}
		final terminal: Null<QueryNode> = returnValue(chain.terminal, s);
		if (terminal == null) return null;
		// Re-bind to a non-null local: narrowing does not reach the struct literal below.
		final terminalValue: QueryNode = terminal;
		final m: Match = { headReturn: chain.branches[0].stmt, pairs: pairs, terminalValue: terminalValue };
		return droppedComment(head, m, comments) ? null : m;
	}

	/** The returned expression of `stmt` when it is a valued `return`; null for a bare `return;` or any other statement. */
	private static function returnValue(stmt: QueryNode, s: Seams): Null<QueryNode> {
		return stmt.kind == s.returnKind && stmt.children.length == RETURN_VALUE_CHILD_COUNT ? stmt.children[0] : null;
	}

	/** Build the `return if (c1) a else if (c2) b … else n;` edit replacing the whole head-`if` span. */
	private static function buildEdit(m: Match, source: String, span: Span): Null<{ span: Span, text: String }> {
		final headSpan: Null<Span> = m.headReturn.span;
		final headValueSpan: Null<Span> = m.pairs[0].value.span;
		if (headSpan == null || headValueSpan == null) return null;
		final prefix: String = source.substring(headSpan.from, headValueSpan.from);
		final built: Array<{ cond: String, value: String }> = [];
		for (p in m.pairs) {
			final cond: Null<String> = slice(source, p.cond);
			final value: Null<String> = slice(source, p.value);
			if (cond == null || value == null) return null;
			built.push({ cond: cond, value: value });
		}
		final terminalValue: Null<String> = slice(source, m.terminalValue);
		if (terminalValue == null) return null;
		return { span: span, text: IfExpressionChain.buildText(prefix, built, terminalValue) };
	}

	/** Whether a comment sits in a region the collapse drops (delegates to `IfExpressionChain` with the kept spans). */
	private static function droppedComment(head: QueryNode, m: Match, comments: Array<{ from: Int, to: Int, isLine: Bool }>): Bool {
		final headSpan: Null<Span> = head.span;
		final headReturnSpan: Null<Span> = m.headReturn.span;
		final headValueSpan: Null<Span> = m.pairs[0].value.span;
		if (headSpan == null || headReturnSpan == null || headValueSpan == null) return false;
		final kept: Array<Span> = [new Span(headReturnSpan.from, headValueSpan.from)];
		for (p in m.pairs) {
			if (p.cond.span != null) kept.push((p.cond.span: Span));
			if (p.value.span != null) kept.push((p.value.span: Span));
		}
		if (m.terminalValue.span != null) kept.push((m.terminalValue.span: Span));
		return IfExpressionChain.droppedComment(headSpan, kept, comments);
	}

	/** The source text of `node`'s span, or null when it has none. */
	private static function slice(source: String, node: QueryNode): Null<String> {
		final span: Null<Span> = node.span;
		return span == null ? null : source.substring(span.from, span.to);
	}

}

/** The `RefShape` kinds `PreferIfExpressionReturn` reads. */
private typedef Seams = {
	var ifKinds: Array<String>;
	var returnKind: String;
	var blockStmtKind: String;
}

/** A matched return chain: the head `return` (for the prefix), the (condition, value) pairs, the terminal value. */
private typedef Match = {
	var headReturn: QueryNode;
	var pairs: Array<{ cond: QueryNode, value: QueryNode }>;
	var terminalValue: QueryNode;
}

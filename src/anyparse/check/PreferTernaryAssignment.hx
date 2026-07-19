package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags an `if (cond) lhs = a; else lhs = b;` whose two branches assign the SAME
 * l-value with the SAME operator, collapsing the pair to a single
 * `lhs = cond ? a : b;`. Purely structural (no type information), so it holds
 * without a type-checker. `Info` -- the code is correct, this is a readability
 * simplification (the sibling of `prefer-ternary-return`, for assignment rather
 * than `return`).
 *
 * ## What is flagged
 *
 * An `if` STATEMENT with an `else` (exactly `[condition, then, else]`) whose:
 *
 * - else branch is NOT itself an `if` -- an else-if chain is `prefer-switch`
 *   territory and is left alone;
 * - both branches are exactly ONE statement -- a bare `lhs = e;` expression
 *   statement or a braced `{ lhs = e; }` wrapping exactly one (a multi-statement
 *   block is deliberately grouped and never matched);
 * - both statements are BINARY assignments (an l-value and an r-value) of the
 *   SAME operator kind -- plain `=`, or an identical compound `+=` / `??=` / ...
 *   on both sides (`++` / `--`, being single-operand, never match; a `=` paired
 *   with a `+=`, or two different compound ops, never match);
 * - the two l-values are TEXTUALLY IDENTICAL (whitespace-normalized source).
 *
 * A null-narrowing guard condition (`x != null && x.f`) is skipped: the ternary
 * condition would lose the in-condition narrowing and fail to compile under
 * `@:nullSafety(Strict)`. The reported span is the whole `if` statement.
 *
 * ## Autofix
 *
 * `fix` replaces the whole `if`/`else` with `lhs op cond ? thenRhs : elseRhs;`.
 * The l-value and operator are copied verbatim from the then-branch, the two
 * r-values and the condition verbatim from their spans, so the one surviving
 * l-value evaluation (down from two textual occurrences -- the safe direction)
 * matches the original exactly. The condition is wrapped in parentheses only
 * when it binds no tighter than `?:` (a ternary or an assignment); every
 * tighter-binding condition is emitted bare, per the no-redundant-parens
 * preference. A comment inside a DROPPED region of the collapsed `if` (the
 * header, the else l-value, the braces) would be lost, so such an `if` is left
 * unflagged -- following `prefer-safe-nav`'s comment guard. Needs
 * `ifStatementKinds`, `exprStatementKind`, `blockStmtKind` (any unset makes the
 * check a no-op).
 */
@:nullSafety(Strict)
final class PreferTernaryAssignment implements Check {

	/** An `if` with an `else` has exactly [condition, then-branch, else-branch] children. */
	private static inline final IF_ELSE_CHILD_COUNT: Int = 3;

	/** A binary assignment node has exactly [l-value, r-value] children. */
	private static inline final ASSIGN_CHILD_COUNT: Int = 2;

	public function new() {}

	public function id(): String {
		return 'prefer-ternary-assignment';
	}

	public function description(): String {
		return 'an if/else assigning the same l-value in both branches, collapsible to a single ternary assignment';
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
				return m == null ? null : buildEdit(m, source, span, seams);
			});
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Bundle the required + optional `RefShape` kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(shape: RefShape): Null<Seams> {
		final ifKinds: Null<Array<String>> = shape.ifStatementKinds;
		if (ifKinds == null || ifKinds.length == 0) return null;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		if (exprStmtKind == null) return null;
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		return blockStmtKind == null ? null : {
			ifKinds: ifKinds,
			exprStmtKind: exprStmtKind,
			blockStmtKind: blockStmtKind,
			assignKinds: shape.writeParentKinds,
			shape: shape
		};
	}

	/** Walk `node`, flagging each `if`/`else` whose two branches assign the same l-value with the same operator. */
	private static function walk(
		node: QueryNode, out: Array<Violation>, file: String, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>,
		s: Seams, ?parent: QueryNode
	): Void {
		if (s.ifKinds.contains(node.kind) && !isElseIfLink(node, parent, s)) {
			final m: Null<Match> = match(node, source, comments, s);
			if (m != null) {
				final span: Null<Span> = node.span;
				if (span != null) out.push({
					file: file,
					span: span,
					rule: 'prefer-ternary-assignment',
					severity: Severity.Info,
					message: 'this if/else assignment can be a single ternary assignment'
				});
			}
		}
		for (c in node.children) walk(c, out, file, source, comments, s, node);
	}

	/**
	 * If `ifNode` is an `if`/`else` (no else-if) whose two branches are each a single
	 * binary assignment to a textually identical l-value with the same operator, and
	 * neither the condition carries a null-narrowing guard nor a comment sits in a
	 * dropped region, return the match parts; else null.
	 */
	private static function match(
		ifNode: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams
	): Null<Match> {
		if (ifNode.children.length != IF_ELSE_CHILD_COUNT) return null;
		final condition: QueryNode = ifNode.children[0];
		final elseBranch: QueryNode = ifNode.children[2];
		if (s.ifKinds.contains(elseBranch.kind)) return null;
		if (RefactorSupport.hasNullNarrowingGuard(condition, s.shape)) return null;
		final thenRaw: Null<QueryNode> = assignmentIn(ifNode.children[1], s);
		final elseRaw: Null<QueryNode> = assignmentIn(elseBranch, s);
		if (thenRaw == null || elseRaw == null) return null;
		final thenAssign: QueryNode = thenRaw;
		final elseAssign: QueryNode = elseRaw;
		if (thenAssign.kind != elseAssign.kind) return null;
		if (!sameLvalue(thenAssign.children[0], elseAssign.children[0], source)) return null;
		final m: Match = {
			condition: condition,
			thenAssign: thenAssign,
			thenRhs: thenAssign.children[1],
			elseRhs: elseAssign.children[1]
		};
		return droppedComment(ifNode, m, comments) ? null : m;
	}

	/**
	 * The lone binary assignment (two children: l-value, r-value) that is the single
	 * statement of `branch` -- a bare `x = e;` expression statement or a braced
	 * `{ x = e; }` wrapping exactly one. Null when `branch` is not a single binary
	 * assignment statement (increment / decrement, being one-operand, are excluded).
	 */
	private static function assignmentIn(branch: QueryNode, s: Seams): Null<QueryNode> {
		final stmt: QueryNode = if (branch.kind == s.blockStmtKind && branch.children.length == 1)
			branch.children[0]
		else
			branch;
		if (stmt.kind != s.exprStmtKind || stmt.children.length != 1) return null;
		final assign: QueryNode = stmt.children[0];
		return s.assignKinds.contains(assign.kind) && assign.children.length == ASSIGN_CHILD_COUNT ? assign : null;
	}

	/** Whether two l-value subtrees have identical whitespace-normalized source. */
	private static function sameLvalue(a: QueryNode, b: QueryNode, source: String): Bool {
		final aSpan: Null<Span> = a.span;
		final bSpan: Null<Span> = b.span;
		return aSpan != null && bSpan != null
			&& normalize(source.substring(aSpan.from, aSpan.to)) == normalize(source.substring(bSpan.from, bSpan.to));
	}

	/** Collapse whitespace runs to a single space and trim -- the l-value equality key. */
	private static function normalize(s: String): String {
		return StringTools.trim((~/\s+/g).replace(s, ' '));
	}

	/** Build the `lhs op cond ? thenRhs : elseRhs;` edit replacing the whole `if`/`else` span. */
	private static function buildEdit(m: Match, source: String, span: Span, s: Seams): Null<{ span: Span, text: String }> {
		final thenSpan: Null<Span> = m.thenAssign.span;
		final thenRhsSpan: Null<Span> = m.thenRhs.span;
		final condSpan: Null<Span> = m.condition.span;
		final elseRhsSpan: Null<Span> = m.elseRhs.span;
		if (thenSpan == null || thenRhsSpan == null || condSpan == null || elseRhsSpan == null) return null;
		final prefix: String = source.substring(thenSpan.from, thenRhsSpan.from);
		final condition: String = wrapCondition(source.substring(condSpan.from, condSpan.to), m.condition.kind, s.shape);
		final thenRhs: String = source.substring(thenRhsSpan.from, thenRhsSpan.to);
		final elseRhs: String = source.substring(elseRhsSpan.from, elseRhsSpan.to);
		return { span: span, text: '${prefix + condition} ? $thenRhs : $elseRhs;' };
	}

	/** Parenthesise the condition iff it binds no tighter than `?:` (a ternary or an assignment); else emit it bare. */
	private static function wrapCondition(source: String, kind: String, shape: RefShape): String {
		final ternaryKind: Null<String> = shape.ternaryKind;
		final needsParens: Bool = (ternaryKind != null && kind == ternaryKind) || shape.writeParentKinds.contains(kind);
		return needsParens ? '($source)' : source;
	}

	/**
	 * Whether a comment sits inside the collapsed `if` region `[ifSpan.from, ifSpan.to)`
	 * but outside every verbatim-copied span (`kept`: the condition, the then-assignment,
	 * the else r-value). Such a comment would be dropped by the rebuild, so the finding is
	 * skipped rather than silently losing it.
	 */
	private static function droppedComment(ifNode: QueryNode, m: Match, comments: Array<{ from: Int, to: Int, isLine: Bool }>): Bool {
		final ifSpan: Null<Span> = ifNode.span;
		final condSpan: Null<Span> = m.condition.span;
		final thenSpan: Null<Span> = m.thenAssign.span;
		final elseRhsSpan: Null<Span> = m.elseRhs.span;
		if (ifSpan == null || condSpan == null || thenSpan == null || elseRhsSpan == null) return false;
		final kept: Array<Span> = [condSpan, thenSpan, elseRhsSpan];
		for (tok in comments) if (tok.from >= ifSpan.from && tok.to <= ifSpan.to) {
			var inside: Bool = false;
			for (k in kept) if (tok.from >= k.from && tok.to <= k.to) {
				inside = true;
				break;
			}
			if (!inside) return true;
		}
		return false;
	}


	/**
	 * Whether `node` is an `else if` link -- the else-branch (children[2]) of a
	 * parent `if`. Such a link belongs to a chain that is prefer-switch territory,
	 * so it is left unflagged (collapsing it would unravel the chain into nested
	 * ternaries rather than a switch).
	 */
	private static function isElseIfLink(node: QueryNode, parent: Null<QueryNode>, s: Seams): Bool {
		return parent != null && s.ifKinds.contains(parent.kind) && parent.children.length == IF_ELSE_CHILD_COUNT
			&& parent.children[2] == node;
	}

}

/** The `RefShape` kinds `PreferTernaryAssignment` reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	var ifKinds: Array<String>;
	var exprStmtKind: String;
	var blockStmtKind: String;
	var assignKinds: Array<String>;
	var shape: RefShape;
}

/** A matched if/else: the condition, the then-branch assignment, and the two r-values. */
private typedef Match = {
	var condition: QueryNode;
	var thenAssign: QueryNode;
	var thenRhs: QueryNode;
	var elseRhs: QueryNode;
}

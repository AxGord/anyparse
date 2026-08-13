package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.CheckScan.NegationSeams;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags an `if (cond) { a = true; b = false; } else { a = false; b = true; }` -- an `if`/`else`
 * whose branches assign OPPOSITE boolean literals to the same ordered set of two or more targets
 * -- and collapses it to the direct `a = cond; b = !cond;`. `Info`: the code is correct, this is
 * a readability simplification.
 *
 * ## Why not `prefer-ternary-assignment`
 *
 * A ONE-target pair is already covered there: it collapses to `a = cond ? true : false`, which
 * `simplify-boolean-ternary` reduces to `a = cond` on the next `--fix` pass. That check
 * deliberately refuses a multi-statement block, and rightly so for VALUE branches -- collapsing
 * `if (c) { a = 1; b = 2; } else { a = 3; b = 4; }` would write `c` into two ternaries, paying a
 * duplicated condition for nothing. Boolean literals are the one r-value shape whose collapse
 * leaves NO ternary behind, so several targets stay readable. The two checks are disjoint by
 * construction: this one requires at least `MIN_TARGETS` assignments per branch, so no site is
 * ever reported twice.
 *
 * ## What is flagged
 *
 * An `if` STATEMENT with an `else` (exactly `[condition, then, else]`) whose:
 *
 * - node is a direct child of a statement list (`ControlFlowSupport.blockKinds()`). A brace-less
 *   body position (`for (x in xs) if (c) { … } else { … }`) is REFUSED: the replacement is
 *   several statements, and only the first would stay inside the enclosing construct. The same
 *   gate excludes an else-if link, whose parent is the outer `if`;
 * - both branches are BLOCKS holding the same number (>= `MIN_TARGETS`) of statements, each a
 *   plain `=` assignment (`assignKind`, an l-value and an r-value);
 * - the two branches' l-values are TEXTUALLY IDENTICAL, in the same ORDER -- a target's own
 *   setter may have side effects, so the sequence is preserved verbatim;
 * - every r-value is a boolean literal, and the two literals of a target DIFFER. A target
 *   carrying the same literal in both branches does not depend on `cond` at all -- hoisting it
 *   out of the `if` is `tail-merge`'s job, so the whole site is left alone rather than half
 *   rewritten.
 *
 * ## Why the condition must be a plain read path
 *
 * The rewrite evaluates `cond` once PER TARGET where the `if` evaluated it once -- the unsafe
 * direction, unlike the l-value collapse in `prefer-ternary-assignment`. So the condition is
 * accepted only as an identifier or a chain of plain field accesses over one (`selected`,
 * `this.state.active`), optionally under a single logical-not; anything else -- a call, an index
 * or map access, a comparison, a `&&` chain, a null-safe access -- is refused. That keeps the
 * duplication free of side effects and of repeated work, keeps the emitted text short enough
 * that N copies still read well, and (since a `?.` access projects as its own kind) keeps a
 * `Null<Bool>` condition out, whose direct assignment would not mean what the `if` meant.
 *
 * ## Why a shared path segment refuses the site
 *
 * `if (a) { a = false; b = true; } else { a = true; b = false; }` must NOT become
 * `a = !a; b = a;` -- the second statement reads an `a` the first one already overwrote. The
 * gate is symmetric and spelling-agnostic: a site is refused when any target path and the
 * condition path share a single dot-separated segment, which covers the self-assignment above,
 * the `this.`-qualified spelling of it, and the aliasing shapes (`cond = x.flag`, target
 * `y.flag`) that a textual prefix test would miss. What it cannot see is a target whose SETTER
 * mutates the condition -- undecidable from the tree, and shared with every sibling check.
 *
 * ## Autofix
 *
 * `fix` replaces the whole `if`/`else` with one `lhs = cond;` / `lhs = !cond;` statement per
 * target, at the `if`'s own indentation. Each l-value and its `=` are copied verbatim from the
 * then-branch, the condition verbatim from its span, and the negation comes from
 * `NegationScan.negateConditionText` -- so `if (!x)` yields `a = !x; b = x;` rather than a
 * double negation. A comment inside a DROPPED region (the header, the braces, the else branch)
 * would be lost, so such an `if` is left unflagged. Needs `ifStatementKinds`, `exprStatementKind`,
 * `blockStmtKind`, `assignKind`, `boolLitKind` and a `ControlFlowSupport` (any unset makes the
 * check a no-op).
 */
@:nullSafety(Strict)
final class SimplifyBooleanBranchAssignment implements Check {

	/** An `if` with an `else` has exactly [condition, then-branch, else-branch] children. */
	private static inline final IF_ELSE_CHILD_COUNT: Int = 3;

	/** A binary assignment node has exactly [l-value, r-value] children. */
	private static inline final ASSIGN_CHILD_COUNT: Int = 2;

	/** Fewer targets than this is `prefer-ternary-assignment`'s single-l-value case. */
	private static inline final MIN_TARGETS: Int = 2;

	public function new() {}

	public function id(): String {
		return 'simplify-boolean-branch-assignment';
	}

	public function description(): String {
		return 'an if/else assigning opposite boolean literals to several targets, collapsible to direct condition assignments';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
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
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = RefactorSupport.collectCommentTokens(source);
		final edits: Array<{ span: Span, text: String }> =
			CheckScan.applyBySpan(plugin, source, violations, seams.ifKinds, (node, span) -> {
				final m: Null<Match> = match(node, source, comments, seams);
				return m == null ? null : buildEdit(m, source, span, seams);
			});
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Bundle the required + optional seams, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final ifKinds: Null<Array<String>> = shape.ifStatementKinds;
		if (ifKinds == null || ifKinds.length == 0) return null;
		final control: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (control == null) return null;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		if (exprStmtKind == null) return null;
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		if (blockStmtKind == null) return null;
		final assignKind: Null<String> = shape.assignKind;
		if (assignKind == null) return null;
		final boolLitKind: Null<String> = shape.boolLitKind;
		return boolLitKind == null ? null : {
			ifKinds: ifKinds,
			exprStmtKind: exprStmtKind,
			blockStmtKind: blockStmtKind,
			assignKind: assignKind,
			boolLitKind: boolLitKind,
			blockKinds: control.blockKinds(),
			negation: NegationScan.negationSeams(shape),
			logic: plugin.booleanLogicSupport(),
			shape: shape
		};
	}

	/** Walk `node`, flagging each statement-position `if`/`else` whose branches are opposite boolean flag sets. */
	private static function walk(
		node: QueryNode, out: Array<Violation>, file: String, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>,
		s: Seams, ?parent: QueryNode
	): Void {
		if (
			s.ifKinds.contains(node.kind) && parent != null && s.blockKinds.contains(parent.kind)
			&& match(node, source, comments, s) != null
		) {
			final span: Null<Span> = node.span;
			if (span != null) out.push({
				file: file,
				span: span,
				rule: 'simplify-boolean-branch-assignment',
				severity: Severity.Info,
				message: 'these if/else branches can assign the condition to each target directly'
			});
		}
		for (c in node.children) walk(c, out, file, source, comments, s, node);
	}

	/**
	 * The match parts when `ifNode` is an `if`/`else` whose two branch blocks assign opposite
	 * boolean literals to the same ordered target set, the condition is a plain read path that
	 * shares no path segment with a target, and no comment sits in a dropped region; else null.
	 */
	private static function match(
		ifNode: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams
	): Null<Match> {
		if (ifNode.children.length != IF_ELSE_CHILD_COUNT) return null;
		final condition: QueryNode = ifNode.children[0];
		final thenAssigns: Null<Array<QueryNode>> = assignmentsIn(ifNode.children[1], s);
		final elseAssigns: Null<Array<QueryNode>> = assignmentsIn(ifNode.children[2], s);
		if (thenAssigns == null || elseAssigns == null) return null;
		if (thenAssigns.length < MIN_TARGETS || thenAssigns.length != elseAssigns.length) return null;
		final condPath: Null<Array<String>> = readPathSegments(condition, source, s);
		if (condPath == null) return null;
		final pairs: Array<Pair> = [];
		for (i in 0...thenAssigns.length) {
			final thenAssign: QueryNode = thenAssigns[i];
			final elseAssign: QueryNode = elseAssigns[i];
			final lvalue: Null<String> = normalizedText(thenAssign.children[0], source);
			if (lvalue == null || lvalue != normalizedText(elseAssign.children[0], source)) return null;
			if (sharesSegment(condPath, lvalue)) return null;
			final thenLit: Null<Bool> = boolLiteralOf(thenAssign.children[1], source, s);
			final elseLit: Null<Bool> = boolLiteralOf(elseAssign.children[1], source, s);
			if (thenLit == null || elseLit == null) return null;
			final positive: Bool = thenLit;
			if (positive == elseLit) return null;
			pairs.push({ assign: thenAssign, rhs: thenAssign.children[1], positive: positive });
		}
		final m: Match = { condition: condition, pairs: pairs };
		return droppedComment(ifNode, m, comments) ? null : m;
	}

	/**
	 * The plain `=` assignments of `branch`, when it is a BLOCK whose every statement is one.
	 * Null when `branch` is not a block (a bare statement, or an else-if link) or holds anything
	 * else -- a compound operator (`+=`, `??=`), an increment, a call, a nested `if`.
	 */
	private static function assignmentsIn(branch: QueryNode, s: Seams): Null<Array<QueryNode>> {
		if (branch.kind != s.blockStmtKind) return null;
		final out: Array<QueryNode> = [];
		for (stmt in branch.children) {
			if (stmt.kind != s.exprStmtKind || stmt.children.length != 1) return null;
			final assign: QueryNode = stmt.children[0];
			if (assign.kind != s.assignKind || assign.children.length != ASSIGN_CHILD_COUNT) return null;
			out.push(assign);
		}
		return out;
	}

	/**
	 * The dot-separated segments of `cond` read as a plain path -- an identifier or a chain of
	 * field accesses over one, under at most one logical-not and any parentheses. Null for every
	 * other condition shape, which the rewrite must not duplicate per target.
	 */
	private static function readPathSegments(cond: QueryNode, source: String, s: Seams): Null<Array<String>> {
		var node: QueryNode = RefactorSupport.unwrapParens(cond, s.shape.parenKind);
		final notKind: Null<String> = s.negation.notKind;
		if (notKind != null && node.kind == notKind && node.children.length == 1)
			node = RefactorSupport.unwrapParens(node.children[0], s.shape.parenKind);
		if (!isReadPath(node, s)) return null;
		final text: Null<String> = normalizedText(node, source);
		return text?.split('.');
	}

	/** Whether `node` is an identifier or a chain of plain field accesses bottoming out in one. */
	private static function isReadPath(node: QueryNode, s: Seams): Bool {
		if (node.kind == s.shape.identKind) return true;
		final fieldAccessKind: Null<String> = s.shape.fieldAccessKind;
		return fieldAccessKind != null && node.kind == fieldAccessKind && node.children.length == 1 && isReadPath(node.children[0], s);
	}

	/**
	 * Whether the target l-value `lvalue` and the condition path `condPath` share a
	 * dot-separated segment -- the conservative alias test that keeps a rewrite from reading a
	 * value an earlier emitted statement has already overwritten.
	 */
	private static function sharesSegment(condPath: Array<String>, lvalue: String): Bool {
		for (segment in lvalue.split('.')) if (condPath.contains(segment)) return true;
		return false;
	}

	/** The value of `node` when it is a boolean literal, else null. */
	private static function boolLiteralOf(node: QueryNode, source: String, s: Seams): Null<Bool> {
		if (node.kind != s.boolLitKind) return null;
		final text: Null<String> = normalizedText(node, source);
		return switch (text) {
			case 'true': true;
			case 'false': false;
			case null, _: null;
		};
	}

	/** The node's source with every whitespace run removed -- the path / l-value equality key. */
	private static function normalizedText(node: QueryNode, source: String): Null<String> {
		final span: Null<Span> = node.span;
		return span == null ? null : (~/\s+/g).replace(source.substring(span.from, span.to), '');
	}

	/** Build the one-statement-per-target edit replacing the whole `if`/`else` span. */
	private static function buildEdit(m: Match, source: String, span: Span, s: Seams): Null<{ span: Span, text: String }> {
		final condSpan: Null<Span> = m.condition.span;
		if (condSpan == null) return null;
		final positive: String = source.substring(condSpan.from, condSpan.to);
		final negative: String = NegationScan.negateConditionText(m.condition, source, s.negation, s.logic);
		final indent: String = RefactorSupport.lineIndentAt(source, span.from);
		final statements: Array<String> = [];
		for (p in m.pairs) {
			final assignSpan: Null<Span> = p.assign.span;
			final rhsSpan: Null<Span> = p.rhs.span;
			if (assignSpan == null || rhsSpan == null) return null;
			statements.push('${source.substring(assignSpan.from, rhsSpan.from) + (p.positive ? positive : negative)};');
		}
		return { span: span, text: statements.join('\n$indent') };
	}

	/**
	 * Whether a comment sits inside the collapsed `if` region but outside every verbatim-copied
	 * span (the condition and each then-branch assignment). Such a comment would be dropped by
	 * the rebuild, so the finding is skipped rather than silently losing it.
	 */
	private static function droppedComment(ifNode: QueryNode, m: Match, comments: Array<{ from: Int, to: Int, isLine: Bool }>): Bool {
		final ifSpan: Null<Span> = ifNode.span;
		final condSpan: Null<Span> = m.condition.span;
		if (ifSpan == null || condSpan == null) return false;
		final kept: Array<Span> = [condSpan];
		for (p in m.pairs) {
			final assignSpan: Null<Span> = p.assign.span;
			if (assignSpan == null) return true;
			kept.push(assignSpan);
		}
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

}

/** The seams `SimplifyBooleanBranchAssignment` reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	var ifKinds: Array<String>;
	var exprStmtKind: String;
	var blockStmtKind: String;
	var assignKind: String;
	var boolLitKind: String;
	var blockKinds: Array<String>;
	var negation: NegationSeams;
	var logic: Null<BooleanLogicSupport>;
	var shape: RefShape;
}

/** One target of a matched site: its then-branch assignment, that assignment's literal, and which value it carries. */
private typedef Pair = {
	var assign: QueryNode;
	var rhs: QueryNode;
	var positive: Bool;
}

/** A matched if/else: the condition, and one `Pair` per assigned target in branch order. */
private typedef Match = {
	var condition: QueryNode;
	var pairs: Array<Pair>;
}

package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a collapsible `if` — an `if` whose sole then-branch is another `if`, neither
 * carrying an `else` (`if (a) { if (b) … }`). The two conditions can be merged with `&&`
 * (`if (a && b) …`), behaviour-preserving because `&&` short-circuits exactly as the
 * nested `if`s do. `Severity.Warning`; `fix` performs the merge.
 *
 * ## Grammar-agnostic
 *
 * `if` kinds come from `RefShape.ifStatementKinds`; a brace-wrapped single-statement
 * then-branch is unwrapped via `RefShape.blockStmtKind`. The merge joins the conditions
 * with `RefShape.andOperatorText` and parenthesizes an operand whose kind is in
 * `RefShape.andLowerPrecedenceKinds` (so `if (a || c) if (b)` collapses to
 * `if ((a || c) && b)`, not the mis-precedenced `a || c && b`). Unset `ifStatementKinds`
 * makes the check a no-op; unset `andOperatorText` disables only the autofix.
 */
@:nullSafety(Strict)
final class CollapsibleIf implements Check {

	public function new() {}

	public function id(): String {
		return 'collapsible-if';
	}

	public function description(): String {
		return 'a nested if with no else that can be merged with && (if (a) if (b) …)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		if (ifKinds.length == 0) return [];
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, tree, ifKinds, blockStmtKind);
		}
		return violations;
	}

	/** Merge each flagged outer `if` with its nested `if` via `&&`. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		final andOp: Null<String> = shape.andOperatorText;
		if (ifKinds.length == 0 || andOp == null) return [];
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		final wrapKinds: Array<String> = shape.andLowerPrecedenceKinds ?? [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];

		final nodeByKey: Map<String, QueryNode> = [];
		indexIfs(tree, ifKinds, nodeByKey);

		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final vspan: Null<Span> = v.span;
			if (vspan == null) continue;
			final outer: Null<QueryNode> = nodeByKey['${vspan.from}:${vspan.to}'];
			if (outer == null || outer.children.length != 2) continue;
			final outerCond: QueryNode = outer.children[0];
			final thenBranch: QueryNode = outer.children[1];
			final innerIf: QueryNode = unwrapBlock(thenBranch, blockStmtKind);
			if (!ifKinds.contains(innerIf.kind) || innerIf.children.length != 2) continue;
			final innerCond: QueryNode = innerIf.children[0];
			final innerThen: QueryNode = innerIf.children[1];
			final cs: Null<Span> = outerCond.span;
			final ts: Null<Span> = thenBranch.span;
			final ics: Null<Span> = innerCond.span;
			final its: Null<Span> = innerThen.span;
			if (cs == null || ts == null || ics == null || its == null) continue;
			final merged: String = '${wrap(source.substring(cs.from, cs.to), outerCond, wrapKinds)} $andOp ${wrap(source.substring(ics.from, ics.to), innerCond, wrapKinds)}';
			edits.push({ span: cs, text: merged });
			edits.push({ span: ts, text: source.substring(its.from, its.to) });
		}
		return edits;
	}

	/**
	 * Walk `node`; when an `if` with no `else` has a nested `if` with no `else` as its sole
	 * then-branch, flag the outer and STOP (the merge subsumes its subtree; a deeper nested
	 * collapse is found on a re-run, which keeps fixes non-overlapping).
	 */
	private static function walk(
		out: Array<Violation>, file: String, node: QueryNode, ifKinds: Array<String>, blockStmtKind: Null<String>
	): Void {
		if (ifKinds.contains(node.kind) && node.children.length == 2) {
			final innerIf: QueryNode = unwrapBlock(node.children[1], blockStmtKind);
			if (ifKinds.contains(innerIf.kind) && innerIf.children.length == 2) {
				final span: Null<Span> = node.span;
				if (span != null) {
					out.push({
						file: file,
						span: span,
						rule: 'collapsible-if',
						severity: Severity.Warning,
						message: 'this if can be merged with its nested if using &&'
					});
					return;
				}
			}
		}
		for (c in node.children) walk(out, file, c, ifKinds, blockStmtKind);
	}

	/** Unwrap single-statement `{ … }` layers to reach the wrapped statement. */
	private static function unwrapBlock(node: QueryNode, blockStmtKind: Null<String>): QueryNode {
		var n: QueryNode = node;
		while (blockStmtKind != null && n.kind == blockStmtKind && n.children.length == 1) n = n.children[0];
		return n;
	}

	/** Parenthesize `src` iff `node`'s kind binds no tighter than `&&`. */
	private static function wrap(src: String, node: QueryNode, wrapKinds: Array<String>): String {
		return wrapKinds.contains(node.kind) ? '($src)' : src;
	}

	/** Index every `if` node by its `from:to` span key. */
	private static function indexIfs(node: QueryNode, ifKinds: Array<String>, out: Map<String, QueryNode>): Void {
		if (ifKinds.contains(node.kind)) {
			final span: Null<Span> = node.span;
			if (span != null) out['${span.from}:${span.to}'] = node;
		}
		for (c in node.children) indexIfs(c, ifKinds, out);
	}

}

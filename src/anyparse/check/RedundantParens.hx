package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags redundant parentheses — a parenthesized expression wrapped directly in
 * another (`((e))`), whose outer pair adds nothing. `Info` severity (a cosmetic
 * cleanup); `fix` unwraps the redundant layers down to a single pair (`((e))` /
 * `(((e)))` → `(e)`). A lone `(e)` is never flagged — those parens may be
 * load-bearing for precedence.
 *
 * ## Grammar-agnostic
 *
 * The parenthesized-expression kind comes from `RefShape.parenKind` (unset →
 * no-op). The check flags the OUTERMOST paren of a redundant chain and does not
 * descend into it, so a deep chain yields one finding and one non-overlapping
 * fix.
 */
@:nullSafety(Strict)
final class RedundantParens implements Check {

	public function new() {}

	public function id(): String {
		return 'redundant-parens';
	}

	public function description(): String {
		return 'a parenthesized expression redundantly wrapped in another (((e)))';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final parenKind: Null<String> = plugin.refShape().parenKind;
		if (parenKind == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, tree, parenKind);
		}
		return violations;
	}

	/** Unwrap each flagged redundant-paren chain down to a single pair. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final parenKind: Null<String> = plugin.refShape().parenKind;
		if (parenKind == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];

		final nodeByKey: Map<String, QueryNode> = [];
		indexParens(tree, parenKind, nodeByKey);

		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final node: Null<QueryNode> = nodeByKey['${span.from}:${span.to}'];
			if (node == null) continue;
			final inner: Null<Span> = innermost(node, parenKind).span;
			if (inner == null) continue;
			edits.push({ span: span, text: '(${source.substring(inner.from, inner.to)})' });
		}
		return edits;
	}

	/**
	 * Walk `node`; when a paren directly wraps another paren, flag the outer and
	 * STOP (its inner redundant layers are subsumed by the single fix). Otherwise
	 * descend.
	 */
	private static function walk(out: Array<Violation>, file: String, node: QueryNode, parenKind: String): Void {
		if (node.kind == parenKind && node.children.length == 1 && node.children[0].kind == parenKind) {
			final span: Null<Span> = node.span;
			if (span != null) {
				out.push({
					file: file,
					span: span,
					rule: 'redundant-parens',
					severity: Severity.Info,
					message: 'redundant parentheses'
				});
				return;
			}
		}
		for (c in node.children) walk(out, file, c, parenKind);
	}

	/** The innermost node reached by unwrapping single-child paren layers from `node`. */
	private static function innermost(node: QueryNode, parenKind: String): QueryNode {
		var n: QueryNode = node;
		while (n.kind == parenKind && n.children.length == 1) n = n.children[0];
		return n;
	}

	/** Index every paren node by its `from:to` span key. */
	private static function indexParens(node: QueryNode, parenKind: String, out: Map<String, QueryNode>): Void {
		if (node.kind == parenKind) {
			final span: Null<Span> = node.span;
			if (span != null) out['${span.from}:${span.to}'] = node;
		}
		for (c in node.children) indexParens(c, parenKind, out);
	}

}

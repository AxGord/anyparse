package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

/**
 * Shared engine for the collection-literal checks (`prefer-array-literal`,
 * `prefer-map-literal`): each flags an empty-argument `new <typeName>()` that the
 * `[]` literal replaces, and rewrites it to `[]`. `Severity.Info` (a modernization
 * cleanup).
 *
 * The element type survives through the annotation on the assignment target — the
 * convention these checks assume — so `var xs:Array<Int> = new Array()` becomes
 * `var xs:Array<Int> = []`. What `[]` cannot recover is an unannotated target whose only
 * type source is the construction itself: `var xs = new Array<Int>()` loses its element
 * type, and worse, an unannotated `var m = new Map<K, V>()` would become an Array (`[]`
 * infers `Array`, not `Map`). The check has no type information to detect either, so the
 * `--fix` on such a target is left to the human to confirm. The report is always correct
 * (the construction IS replaceable); only the unannotated-target rewrite carries this
 * caveat.
 *
 * ## Grammar-agnostic
 *
 * Driven by `RefShape.newExprKind` (unset → no-op). The constructed type (`Array` /
 * `Map`) is matched on the node `name`, not a kind — per the convention that a literal
 * type name is a node value, not a grammar kind. A node is replaceable only when its
 * source ends in `()` (an empty argument list), so a parseable-but-non-compiling
 * `new Array(x)` never silently drops `x`. The matched node is flagged and not descended
 * into.
 */
@:nullSafety(Strict)
final class NewLiteral {

	public static function run(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, typeName: String, rule: String, message: String
	): Array<Violation> {
		final newExprKind: Null<String> = plugin.refShape().newExprKind;
		if (newExprKind == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, entry.source, tree, newExprKind, typeName, rule, message);
		}
		return violations;
	}

	/** Rewrite each flagged `new <typeName>()` to the `[]` literal. */
	public static function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, typeName: String
	): Array<{ span: Span, text: String }> {
		final newExprKind: Null<String> = plugin.refShape().newExprKind;
		if (newExprKind == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];

		final nodeByKey: Map<String, QueryNode> = [];
		index(tree, newExprKind, nodeByKey);

		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final node: Null<QueryNode> = nodeByKey['${span.from}:${span.to}'];
			if (node == null || !matches(node, source, newExprKind, typeName)) continue;
			edits.push({ span: span, text: '[]' });
		}
		return edits;
	}

	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, newExprKind: String, typeName: String, rule: String,
		message: String
	): Void {
		if (matches(node, source, newExprKind, typeName)) {
			final span: Null<Span> = node.span;
			if (span != null) {
				out.push({
					file: file,
					span: span,
					rule: rule,
					severity: Severity.Info,
					message: message
				});
				return;
			}
		}
		for (c in node.children) walk(out, file, source, c, newExprKind, typeName, rule, message);
	}

	/** Whether `node` is a `new <typeName>()` with an empty argument list (source ends in `()`). */
	private static function matches(node: QueryNode, source: String, newExprKind: String, typeName: String): Bool {
		if (node.kind != newExprKind || node.name != typeName) return false;
		final span: Null<Span> = node.span;
		return span != null && StringTools.endsWith(StringTools.rtrim(source.substring(span.from, span.to)), '()');
	}

	/** Index every `new` node by its `from:to` span key (for `fix` to re-find a flagged node). */
	private static function index(node: QueryNode, newExprKind: String, out: Map<String, QueryNode>): Void {
		if (node.kind == newExprKind) {
			final span: Null<Span> = node.span;
			if (span != null) out['${span.from}:${span.to}'] = node;
		}
		for (c in node.children) index(c, newExprKind, out);
	}

}

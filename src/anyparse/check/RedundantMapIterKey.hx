package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags a key-value `for` loop that discards its key with `_` — `for (_ => v in m)`
 * — which is just `for (v in m)`, since Haxe iterates values by default. `Info` (a
 * modernization matching the idiom), with an autofix that drops the `_ => ` prefix.
 *
 * A value-discarding `for (_ in m)` (no `=>`) is a legitimate "iterate, ignore the
 * value" loop and is NOT flagged — only the key-value form with a discarded key is.
 *
 * ## Grammar-agnostic, with a source-level header scan
 *
 * The loop kind comes from `RefShape.forStmtKind` (unset → no-op) and the iterator
 * variable from the node's `name`. The value variable and the `=>` are not separate
 * AST nodes here, so the key-value shape is detected by scanning the header source
 * between the loop's `(` and its iterable child for `=>`; the fix removes the span
 * from the key to the value variable. The iterable's own `=>` (a map literal,
 * `for (_ => v in [a => b])`) sits after the iterable's start offset and is excluded
 * by bounding the scan to the header.
 */
@:nullSafety(Strict)
final class RedundantMapIterKey implements Check {

	public function new() {}

	public function id(): String {
		return 'redundant-map-iter-key';
	}

	public function description(): String {
		return 'a key-value for loop that discards its key (for (_ => v in m))';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final forStmtKind: Null<String> = plugin.refShape().forStmtKind;
		if (forStmtKind == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, entry.source, tree, forStmtKind);
		}
		return violations;
	}

	/** Drop the `_ => ` discarded-key prefix from each flagged loop header. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final forStmtKind: Null<String> = plugin.refShape().forStmtKind;
		if (forStmtKind == null) return [];
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree == null) return [];

		final nodeByKey: Map<String, QueryNode> = [];
		indexFor(tree, forStmtKind, nodeByKey);

		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final node: Null<QueryNode> = nodeByKey['${span.from}:${span.to}'];
			if (node == null) continue;
			final cut: Null<Span> = keyPrefixSpan(node, source);
			if (cut != null) edits.push({ span: cut, text: '' });
		}
		return edits;
	}

	private static function walk(out: Array<Violation>, file: String, source: String, node: QueryNode, forStmtKind: String): Void {
		if (node.kind == forStmtKind && node.name == '_' && keyPrefixSpan(node, source) != null) {
			final span: Null<Span> = node.span;
			if (span != null) out.push({
				file: file,
				span: span,
				rule: 'redundant-map-iter-key',
				severity: Severity.Info,
				message: 'this loop discards its map key — iterate values directly: for (v in m)'
			});
		}
		// Descend regardless of a match: a discarded-key loop can nest inside another
		// (`for (_ => v in m) for (_ => w in v) …`), and the two are independent — fixing
		// the outer header does nothing for the inner — so both must be reported.
		for (c in node.children) walk(out, file, source, c, forStmtKind);
	}

	/**
	 * The span `[keyStart, valueStart)` to delete for a `for (_ => v in …)` loop whose
	 * key is `_` — null when the loop has no `=>` in its header (a value-only
	 * `for (_ in m)`) or the header cannot be located.
	 */
	private static function keyPrefixSpan(node: QueryNode, source: String): Null<Span> {
		if (node.children.length == 0) return null;
		final forSpan: Null<Span> = node.span;
		final iterSpan: Null<Span> = node.children[0].span;
		if (forSpan == null || iterSpan == null) return null;
		final open: Int = source.indexOf('(', forSpan.from);
		if (open < 0 || open >= iterSpan.from) return null;
		final arrow: Int = source.indexOf('=>', open);
		if (arrow < 0 || arrow >= iterSpan.from) return null;
		final keyStart: Int = skipSpace(source, open + 1, iterSpan.from);
		final valueStart: Int = skipSpace(source, arrow + 2, iterSpan.from);
		// Guard the source scan: the text from the key start to the `=>` must be exactly
		// the discarded key `_`. If the located `(` was a decoy (e.g. one inside a comment
		// between `for` and the real header), this slice is not `_`, so bail — no bogus
		// finding, no corrupt fix.
		if (StringTools.trim(source.substring(keyStart, arrow)) != '_') return null;
		return keyStart < valueStart ? new Span(keyStart, valueStart) : null;
	}

	/** First index at or after `from` (bounded by `stop`) that is not ASCII whitespace. */
	private static function skipSpace(source: String, from: Int, stop: Int): Int {
		var i: Int = from;
		while (i < stop) {
			final c: Int = StringTools.fastCodeAt(source, i);
			if (c != ' '.code && c != '\t'.code && c != '\n'.code && c != '\r'.code) break;
			i++;
		}
		return i;
	}

	/** Index every for-loop node by its `from:to` span key. */
	private static function indexFor(node: QueryNode, forStmtKind: String, out: Map<String, QueryNode>): Void {
		if (node.kind == forStmtKind) {
			final span: Null<Span> = node.span;
			if (span != null) out['${span.from}:${span.to}'] = node;
		}
		for (c in node.children) indexFor(c, forStmtKind, out);
	}

}

package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags an `Add`-chain of adjacent plain string literals that can be merged into
 * one (`"a" + "b"` -> `"ab"`) and folds it. The first transform-style cleanup —
 * a `fix()` that REPLACES the concatenation with the merged literal (the prior
 * checks delete or rename). An `Info` advisory: a cosmetic simplification, not a
 * defect, so it is quiet in the default report but still applied by `--fix`.
 *
 * ## Grammar-agnostic
 *
 * The string semantics live behind `StringFoldSupport` (the plugin seam):
 * `concatKind()` names the binary concat operator and `literalOf()` yields a
 * plain literal's quote + raw content (or null for an interpolated / non-literal
 * operand). A grammar without the seam (binary formats) makes the check a no-op.
 *
 * ## What folds
 *
 * Only a maximal concat sub-tree whose every leaf is a plain literal of the SAME
 * quote — `"a" + "b" + "c"` -> `"abc"` in one pass. A non-literal or interpolated
 * operand, or a mixed-quote pair, blocks the fold at that node; a foldable inner
 * pair inside a partially-foldable chain (`"a" + "b" + name`) still folds on its
 * own. Folding concatenates each literal's RAW inner source and re-wraps in the
 * shared quote, so escapes / `$$` are preserved verbatim.
 */
@:nullSafety(Strict)
final class FoldStringLiterals implements Check {

	public function new() {}

	public function id(): String {
		return 'fold-adjacent-string-literals';
	}

	public function description(): String {
		return 'adjacent string literals that can be merged into one';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final support: Null<StringFoldSupport> = plugin.stringFoldSupport();
		if (support == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, entry.source, tree, support);
		}
		return violations;
	}

	/**
	 * Replace each flagged maximal concat with its merged literal. The violation
	 * span identifies the concat node (matched by full from:to span, since a
	 * left-assoc chain's outer and inner `Add` share the same `from`); the merge
	 * is recomputed and emitted as a single span replacement, batched by the
	 * caller into one re-parse-validated canonicalize per file.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final support: Null<StringFoldSupport> = plugin.stringFoldSupport();
		if (support == null) return [];
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree == null) return [];

		final nodeByKey: Map<String, QueryNode> = [];
		indexConcats(tree, support.concatKind(), nodeByKey);

		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final node: Null<QueryNode> = nodeByKey[spanKey(span)];
			if (node == null) continue;
			final merged: Null<StringLiteral> = folded(node, source, support);
			if (merged == null) continue;
			edits.push({ span: span, text: merged.quote + merged.content + merged.quote });
		}
		return edits;
	}

	/**
	 * Walk `node`; at each maximal foldable concat emit an `Info` and stop (its
	 * inner folds are subsumed). A non-foldable concat is still descended into,
	 * so a foldable inner pair in a partially-foldable chain is found.
	 */
	private static function walk(out: Array<Violation>, file: String, source: String, node: QueryNode, support: StringFoldSupport): Void {
		if (node.kind == support.concatKind() && folded(node, source, support) != null) {
			final span: Null<Span> = node.span;
			if (span != null) {
				out.push({
					file: file,
					span: span,
					rule: 'fold-adjacent-string-literals',
					severity: Severity.Info,
					message: 'adjacent string literals can be merged'
				});
				return;
			}
		}
		for (c in node.children) walk(out, file, source, c, support);
	}

	/**
	 * The merged literal `node` collapses to, or null. A plain literal yields
	 * itself; a binary concat yields the merge of its two operands when both fold
	 * to the SAME quote. Any other shape (non-literal, mixed quotes, a concat
	 * without exactly two operands) does not fold.
	 */
	private static function folded(node: QueryNode, source: String, support: StringFoldSupport): Null<StringLiteral> {
		final literal: Null<StringLiteral> = support.literalOf(node, source);
		if (literal != null) return literal;
		if (node.kind != support.concatKind() || node.children.length != 2) return null;
		final left: Null<StringLiteral> = folded(node.children[0], source, support);
		final right: Null<StringLiteral> = folded(node.children[1], source, support);
		return left == null || right == null
			? null
			: left.quote != right.quote
				? null
				: {
					quote: left.quote,
					content: left.content + right.content
				};
	}

	/** Index every concat node by its full `from:to` span key (a left-assoc chain shares `from`). */
	private static function indexConcats(node: QueryNode, concatKind: String, out: Map<String, QueryNode>): Void {
		if (node.kind == concatKind) {
			final span: Null<Span> = node.span;
			if (span != null) out[spanKey(span)] = node;
		}
		for (c in node.children) indexConcats(c, concatKind, out);
	}

	/** The composite map key for a span — `from` alone collides on a left-assoc chain. */
	private static inline function spanKey(span: Span): String {
		return '${span.from}:${span.to}';
	}

}

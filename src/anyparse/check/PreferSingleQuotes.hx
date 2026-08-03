package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a double-quoted string literal carrying no interpolation `$` and no `'`,
 * and rewrites it to single quotes (`"hi"` -> `'hi'`). `Severity.Info` — a
 * modernization matching the Haxe idiom (single quotes by default), with an
 * autofix.
 *
 * A double-quoted literal is KEPT when its content would mean something else in
 * single quotes — because it holds a `$` (the double quotes deliberately suppress
 * interpolation that single quotes would trigger), because an escape DECODES to one
 * (`"\x24a"` is the text `$a`; `'\x24a'` is the value of the local `a`), or because
 * an unescaped `'` would terminate the single-quoted form. Every other escape
 * (`\"`, `\'`, `\n`, `\t`, `\\`, ...) stays valid verbatim inside single quotes, so
 * the rewrite only swaps the two delimiter characters and copies the inner source
 * unchanged.
 *
 * ## Grammar-agnostic
 *
 * Reuses `StringFoldSupport` (the `fold-adjacent-string-literals` seam): a node
 * for which `literalOf` yields a `quote == '"'` literal is a plain double-quoted
 * string, and `requoteVerbatim` decides — with the grammar's own lexer rules —
 * whether its raw content survives the quote swap. A grammar without string-fold
 * support (binary formats) makes the check a no-op.
 *
 * ## Limitation
 *
 * Without type information the check cannot tell that a flagged literal is the
 * argument of a MACRO whose behaviour branches on the literal's quote kind (the
 * `DoubleQuotes` / `SingleQuotes` tag on `haxe.macro.Expr.CString`). Such a macro
 * is rare and that tag is normally used to round-trip a literal rather than to
 * alter behaviour, so — like the other type-blind checks — this stays an `Info`
 * with an opt-in `--fix` rather than being gated off.
 */
@:nullSafety(Strict)
final class PreferSingleQuotes implements Check {

	public function new() {}

	public function id(): String {
		return 'prefer-single-quotes';
	}

	public function description(): String {
		return 'a double-quoted string with no interpolation that can use single quotes';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final support: Null<StringFoldSupport> = plugin.stringFoldSupport();
		if (support == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			// A project checkstyle `StringLiteral.policy` that prefers double quotes disables this check.
			if (plugin.checkOverrides(entry.file)?.preferSingleQuotesEnabled == false) continue;
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, entry.source, tree, support);
		}
		return violations;
	}

	/** Rewrite each flagged double-quoted literal to its single-quoted form. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final support: Null<StringFoldSupport> = plugin.stringFoldSupport();
		if (support == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];

		final nodeBySpan: Map<String, QueryNode> = [];
		indexLiterals(tree, source, support, nodeBySpan);

		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final node: Null<QueryNode> = nodeBySpan['${span.from}:${span.to}'];
			if (node == null) continue;
			final replacement: Null<String> = single(node, source, support);
			if (replacement == null) continue;
			edits.push({ span: span, text: replacement });
		}
		return edits;
	}

	/** Walk `node`, flagging each convertible double-quoted literal. */
	private static function walk(out: Array<Violation>, file: String, source: String, node: QueryNode, support: StringFoldSupport): Void {
		if (single(node, source, support) != null) {
			final span: Null<Span> = node.span;
			if (span != null) out.push({
				file: file,
				span: span,
				rule: 'prefer-single-quotes',
				severity: Severity.Info,
				message: 'this double-quoted string can use single quotes'
			});
		}
		for (c in node.children) walk(out, file, source, c, support);
	}

	/**
	 * The single-quoted rewrite for `node` when it is a double-quoted literal whose
	 * raw content the grammar will re-spell verbatim between the two quotings; else
	 * null. The judgement is `requoteVerbatim`'s, not this check's: whether a content
	 * byte can END the target quoting or START interpolation is lexer knowledge, and a
	 * local rescan of it would be a second, worse lexer — the one that shipped the
	 * `"\x24a"` value change (the escape decodes to `$` before the interpolation scan
	 * runs, so the single-quoted form prints the local `a`).
	 */
	private static function single(node: QueryNode, source: String, support: StringFoldSupport): Null<String> {
		final literal: Null<StringLiteral> = support.literalOf(node, source);
		return literal == null || literal.quote != '"' ? null : support.requoteVerbatim(literal, "'");
	}

	/** Index every convertible double-quoted literal by its `from:to` span key (for `fix` to re-find it). */
	private static function indexLiterals(node: QueryNode, source: String, support: StringFoldSupport, out: Map<String, QueryNode>): Void {
		if (single(node, source, support) != null) {
			final span: Null<Span> = node.span;
			if (span != null) out['${span.from}:${span.to}'] = node;
		}
		for (c in node.children) indexLiterals(c, source, support, out);
	}

}

package anyparse.check.common.members;

import anyparse.check.Check.FixEdit;
import anyparse.query.SymbolIndex;

/**
 * Flags metadata written with an EMPTY argument list — `@:forward()`, `@:keep()`, `@meta()` — and
 * deletes the `()`. `Info`, safe fix. The compiler reads both spellings as the same entry with an
 * empty parameter list, so the parentheses carry nothing; the one answer to "which metadata tags
 * are written with an empty argument list, and which span is the `()`".
 *
 * The finding spans the parentheses only, so a `// noqa` on the meta's line suppresses it and the
 * fix is a plain deletion. Every metadata position is covered, because the scan visits every node
 * of the grammar's `MetaShape.metaKinds` wherever it sits (type, member, local, expression, enum
 * constructor).
 *
 * ## Deliberate misses
 *
 * - A comment between the parentheses: the comment is the reason the parentheses are there, and
 *   deleting them would delete it.
 * - A `(` directly after the `)` (`@:keep()(x)`): removing the empty pair would hand the next
 *   parenthesis to the metadata as its argument list.
 */
@:nullSafety(Strict)
final class RedundantMetaParens extends RuleBase {

	/** This check's stable id. */
	private static inline final RULE_ID: String = 'redundant-meta-parens';

	public function new() {
		super(RULE_ID, 'a metadata tag written with an empty argument list — the () adds nothing', RuleCategory.Members);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final kinds: Array<String> = plugin.metaShape().metaKinds;
		return RunScan.collect(files, plugin, (entry, tree, out) -> collectParens(tree, kinds, entry.source, entry.file, out));
	}

	/** Delete each flagged `()`; a span that no longer holds exactly an empty argument list is left alone. */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return RunScan.spanEdits(
			violations, (_, span) -> isEmptyParens(source.substring(span.from, span.to)) ? { span: span, text: '' } : null
		);
	}

	/** Report the empty argument list of every metadata node under `node`, in source order. */
	private static function collectParens(
		node: QueryNode, kinds: Array<String>, source: String, file: String, out: Array<Violation>
	): Void {
		final parens: Null<Span> = kinds.contains(node.kind) ? emptyParensOf(node, source) : null;
		if (parens != null) out.push({
			file: file,
			span: parens,
			rule: RULE_ID,
			severity: Severity.Info,
			message: 'redundant parentheses on ${node.name}: an empty argument list is the same metadata as none'
		});
		for (child in node.children) collectParens(child, kinds, source, file, out);
	}

	/** The `()` span of the metadata `node` when it is exactly an empty argument list directly after the name, else null. */
	private static function emptyParensOf(node: QueryNode, source: String): Null<Span> {
		final name: Null<String> = node.name;
		final span: Null<Span> = node.span;
		if (name == null || span == null || node.children.length > 0) return null;
		final text: String = source.substring(span.from, span.to);
		return !text.startsWith(name)
			|| !isEmptyParens(text.substr(name.length))
			|| (span.to < source.length && source.charAt(span.to) == '(')
			? null
			: new Span(span.from + name.length, span.to);
	}

	/** Whether `text` is an opening parenthesis, a closing one and nothing but whitespace between. */
	private static function isEmptyParens(text: String): Bool {
		return text.length >= 2
			&& text.charAt(0) == '('
			&& text.charAt(text.length - 1) == ')'
			&& text.substring(1, text.length - 1).trim() == '';
	}

}

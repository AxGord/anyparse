package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags a stray empty statement — a lone `;` with no expression (SonarLint
 * S1116), usually an editing leftover or a misplaced terminator. Purely
 * structural. `Warning`; `fix` deletes the `;` — the whole physical line when the
 * `;` sits alone on it (so no blank residue is left), otherwise only the `;`
 * itself (e.g. the trailing `;` of `g();;`).
 *
 * ## Grammar-agnostic
 *
 * The empty-statement node kind comes from `RefShape.emptyStmtKind`; unset makes
 * the check a no-op.
 */
@:nullSafety(Strict)
final class EmptyStatement implements Check {

	public function new() {}

	public function id(): String {
		return 'empty-statement';
	}

	public function description(): String {
		return 'a stray empty statement (a lone ;)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final emptyStmtKind: Null<String> = plugin.refShape().emptyStmtKind;
		if (emptyStmtKind == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, tree, emptyStmtKind);
		}
		return violations;
	}

	/** Delete each flagged empty statement. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) edits.push({ span: deletionSpan(source, span), text: '' });
		}
		return edits;
	}

	/** Walk `node`, flagging every empty statement reached. */
	private static function walk(out: Array<Violation>, file: String, node: QueryNode, emptyStmtKind: String): Void {
		if (node.kind == emptyStmtKind) {
			final span: Null<Span> = node.span;
			if (span != null) out.push({
				file: file,
				span: span,
				rule: 'empty-statement',
				severity: Severity.Warning,
				message: 'empty statement'
			});
		}
		for (c in node.children) walk(out, file, c, emptyStmtKind);
	}

	/**
	 * The span to delete for the `;` at `span`. When the `;` is alone on its line
	 * (only whitespace around it), the whole physical line is removed so the
	 * batched re-emit leaves no blank line; otherwise only the `;` itself.
	 */
	private static function deletionSpan(source: String, span: Span): Span {
		var lineStart: Int = span.from;
		while (lineStart > 0 && StringTools.fastCodeAt(source, lineStart - 1) != '\n'.code) lineStart--;
		var lineEnd: Int = span.to;
		while (lineEnd < source.length && StringTools.fastCodeAt(source, lineEnd) != '\n'.code) lineEnd++;
		final alone: Bool = StringTools.trim(source.substring(lineStart, span.from)) == ''
			&& StringTools.trim(source.substring(span.to, lineEnd)) == '';
		return alone ? RefactorSupport.lineExtendedSpan(source, span) : span;
	}

}

package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags an empty control-flow block — an `if` / `else` / `while` / `for` /
 * `try` / `catch` body written as `{}` with no statements: a forgotten
 * implementation, or an empty `catch` that silently swallows an error. Purely
 * structural (no type information needed), so it holds even without a
 * type-checker. Report-only: a `Warning` without an autofix in this slice.
 *
 * ## Grammar-agnostic
 *
 * The flaggable block kinds live behind `ControlFlowSupport.emptyFlagKinds()`
 * (the plugin seam shared with `dead-code`). A grammar without the seam (a
 * binary format) makes the check a no-op.
 *
 * ## What is flagged
 *
 * A node whose kind is in `emptyFlagKinds()`, has no child statements, AND whose
 * source between the braces is whitespace-only. A block holding only a comment
 * has no statement children but non-blank inner source — treated as an
 * intentional placeholder and NOT flagged. The function-body kind is excluded
 * from `emptyFlagKinds()`, so an empty `new() {}` constructor is never flagged.
 */
@:nullSafety(Strict)
final class EmptyBlock implements Check {

	public function new() {}

	public function id(): String {
		return 'empty-block';
	}

	public function description(): String {
		return 'an empty control-flow block ({} with no statements) for an if / else / loop / try / catch';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, entry.source, tree, support);
		}
		return violations;
	}

	/** Empty-block has no autofix in this slice — report-only. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/** Walk `node`, flagging every empty control-flow block reached. */
	private static function walk(out: Array<Violation>, file: String, source: String, node: QueryNode, support: ControlFlowSupport): Void {
		final span: Null<Span> = node.span;
		if (span != null && node.children.length == 0 && support.emptyFlagKinds().contains(node.kind) && isBlank(span, source)) out.push({
			file: file,
			span: span,
			rule: 'empty-block',
			severity: Severity.Warning,
			message: 'empty block'
		});
		for (c in node.children) walk(out, file, source, c, support);
	}

	/**
	 * Whether the source `span` covers an empty pair of braces — the span runs
	 * from the opening to the closing brace, so the inner slice (braces dropped)
	 * is whitespace-only. A block containing a comment is non-blank.
	 */
	private static function isBlank(span: Span, source: String): Bool {
		final inner: String = source.substring(span.from + 1, span.to - 1);
		return StringTools.trim(inner) == '';
	}

}

package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags an empty control-flow block — an `if` / `else` / `while` / `for` /
 * `try` / `catch` body written as `{}` with no statements: a forgotten
 * implementation, or an empty `catch` that silently swallows an error. Purely
 * structural (no type information needed), so it holds even without a
 * type-checker. Autofixable in part — `--fix` removes the provably-safe subset
 * (an empty `else {}`, and an empty no-else `if (cond) {}` with a
 * side-effect-free condition); an empty loop, `try`, or `catch` body stays a
 * report-only `Warning`.
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

	/** An if node with both branches has children [cond, then, else]. */
	private static inline final IF_WITH_ELSE_CHILD_COUNT: Int = 3;

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
			// A project checkstyle `EmptyBlock.option` of `empty` (allow empty blocks) disables this check.
			if (plugin.checkOverrides(entry.file)?.emptyBlockEnabled == false) continue;
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, entry.source, tree, support);
		}
		return violations;
	}

	/**
	 * Delete the provably-safe subset of empty blocks: an empty `else {}` (the
	 * ` else {}` is cut, keeping the `if` and its non-empty then-branch) and an
	 * empty no-else `if (cond) {}` whose condition is side-effect-free (the whole
	 * `if` is dropped). The rest stays report-only — an empty loop body or an
	 * empty `if` with a side-effecting condition would lose that evaluation, and
	 * an empty `catch {}` cannot be removed (a `try` needs its catch).
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree == null) return [];

		// Statement-list kinds: a no-else `if (cond) {}` is safe to DELETE only
		// when it sits in one of these; as a single-statement branch body its
		// removal would strand the enclosing branch. Absent seam -> never delete.
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		final blockKinds: Array<String> = support != null ? support.blockKinds() : [];

		final flagged: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push('${span.from}:${span.to}');
		}
		final edits: Array<{ span: Span, text: String }> = [];
		collectEmptyFixes(tree, null, null, source, blockKinds, flagged, edits);
		return RefactorSupport.dropContainedEdits(edits);
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

	/** Walk `node` with its `parent` and `grandparent`, collecting safe deletions for flagged empty blocks. */
	private static function collectEmptyFixes(
		node: QueryNode, parent: Null<QueryNode>, grandparent: Null<QueryNode>, source: String, blockKinds: Array<String>,
		flagged: Array<String>, edits: Array<{ span: Span, text: String }>
	): Void {
		final span: Null<Span> = node.span;
		if (span != null && parent != null && flagged.contains('${span.from}:${span.to}')) {
			final edit: Null<{ span: Span, text: String }> = emptyBlockEdit(node, parent, grandparent, source, blockKinds);
			if (edit != null) edits.push(edit);
		}
		for (c in node.children) collectEmptyFixes(c, node, parent, source, blockKinds, flagged, edits);
	}

	/**
	 * The deletion edit for a flagged empty `BlockStmt` whose `parent` makes it
	 * safe to remove, or null when no safe edit applies. An empty `else` branch
	 * (the parent `if` has a then AND this else) cuts ` else {}`; an empty
	 * no-else then-branch with a side-effect-free condition drops the whole `if`
	 * — but only when that `if` is itself a statement-list member (`grandparent`
	 * is in `blockKinds`). As a single-statement branch body, dropping it would
	 * strand the enclosing branch (a dangling `if` / `else`), so it stays
	 * report-only.
	 */
	private static function emptyBlockEdit(
		node: QueryNode, parent: QueryNode, grandparent: Null<QueryNode>, source: String, blockKinds: Array<String>
	): Null<{ span: Span, text: String }> {
		if (parent.kind != 'IfStmt') return null;
		final nspan: Null<Span> = node.span;
		if (nspan == null) return null;
		final kids: Array<QueryNode> = parent.children;
		// Empty `else {}` — this node is the else branch (then + else both present).
		if (kids.length >= IF_WITH_ELSE_CHILD_COUNT && kids[2] == node) {
			final thenSpan: Null<Span> = kids[1].span;
			return thenSpan == null ? null : { span: RefactorSupport.lineExtendedSpan(source, new Span(thenSpan.to, nspan.to)), text: '' };
		}
		// Empty no-else `if (cond) {}` with a side-effect-free condition — safe to
		// drop only when the `if` is a statement-list member, not a branch body.
		if (
			kids.length == 2 && kids[1] == node && RefactorSupport.isSideEffectFree(kids[0]) && grandparent != null
			&& blockKinds.contains(grandparent.kind)
		) {
			final pspan: Null<Span> = parent.span;
			return pspan == null ? null : { span: RefactorSupport.lineExtendedSpan(source, pspan), text: '' };
		}
		return null;
	}

}

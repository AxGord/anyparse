package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a value-less `return;` that is the LAST statement of a function body —
 * redundant, since control falls off the end of the body to the same effect.
 * Purely structural (no type information); `Info`, with a delete autofix.
 *
 * ## What is flagged — and what is not
 *
 * Only a `voidReturnKind` node that is the final direct child of a function's
 * body block. A `return;` nested inside an `if` / loop / `try` at the end of the
 * body is NOT flagged: it is the last child of that inner block, not of the body
 * itself, and there it guards the statements it skips. A value-returning
 * `return e;` (a distinct kind) never matches. This keeps the check to the one
 * provably-useless form.
 *
 * ## Grammar-agnostic
 *
 * `RefShape.voidReturnKind` is the value-less return kind; `functionKinds` are the
 * function declarations whose body to inspect; `functionBodyKinds` mark the body
 * child (only a statement block has children, so a `=>` expression body or a
 * body-less declaration never yields a trailing void return). Any unset → no-op.
 */
@:nullSafety(Strict)
final class RedundantVoidReturn implements Check {

	public function new() {}

	public function id(): String {
		return 'redundant-void-return';
	}

	public function description(): String {
		return 'a value-less return; as the last statement of a function body';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final voidKind: Null<String> = shape.voidReturnKind;
		final fnKinds: Array<String> = shape.functionKinds ?? [];
		final bodyKinds: Array<String> = shape.functionBodyKinds ?? [];
		if (voidKind == null || fnKinds.length == 0 || bodyKinds.length == 0) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			for (span in collect(tree, voidKind, fnKinds, bodyKinds)) violations.push({
				file: entry.file,
				span: span,
				rule: 'redundant-void-return',
				severity: Severity.Info,
				message: 'redundant trailing return; — control falls off the end of the function'
			});
		}
		return violations;
	}

	/**
	 * Delete each flagged trailing `return;` with its whole line. The violation span
	 * is the void-return node itself (computed against this same `source`), so the
	 * deletion extends it over the physical line (`lineExtendedSpan`) and the caller
	 * batches the empty-text edits into one canonicalize per file.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) edits.push({ span: RefactorSupport.lineExtendedSpan(source, span), text: '' });
		}
		return edits;
	}

	/** The spans of every trailing void-return in `tree` (one per function body at most). */
	private static function collect(tree: QueryNode, voidKind: String, fnKinds: Array<String>, bodyKinds: Array<String>): Array<Span> {
		final spans: Array<Span> = [];
		walk(spans, tree, voidKind, fnKinds, bodyKinds);
		return spans;
	}

	/**
	 * Walk `node`; for a function declaration, inspect each body-kind child and
	 * record its last statement when that is a void return. Recurses so a nested
	 * function's trailing return is caught too (named local functions only; a lambda body is not).
	 */
	private static function walk(
		out: Array<Span>, node: QueryNode, voidKind: String, fnKinds: Array<String>, bodyKinds: Array<String>
	): Void {
		if (fnKinds.contains(node.kind)) {
			for (child in node.children) if (bodyKinds.contains(child.kind) && child.children.length > 0) {
				final last: QueryNode = child.children[child.children.length - 1];
				final span: Null<Span> = last.span;
				if (last.kind == voidKind && span != null) out.push(span);
			}
		}
		for (c in node.children) walk(out, c, voidKind, fnKinds, bodyKinds);
	}

}

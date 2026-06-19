package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags a bare `{ … }` statement block — one written directly inside another
 * block rather than as a control-flow body — that declares no binding of its own,
 * so it is a pure scope with no effect. Purely structural; `Info`, with an unwrap
 * autofix.
 *
 * ## What is flagged
 *
 * A `blockStmtKind` node whose PARENT is itself a block container
 * (`ControlFlowSupport.blockKinds()` — a function body, another statement block,
 * or a block expression) AND which declares no binding directly (no
 * `localDeclKinds` and no local-function `functionKinds` child). The body of an
 * `if` / loop / `try` is a `blockStmtKind` too, but its parent is the control-flow
 * node, not a block container, so it is never flagged. A block that declares a
 * local (a `var` / `final` or a local `function`) is a real scope — unwrapping it
 * could collide with, widen, or hoist a binding — so it is left alone. A
 * metaprogramming-reification subtree (`opaqueKinds`) is skipped wholesale: a block
 * the macro emits is structural, not author noise.
 *
 * ## Autofix
 *
 * `--fix` unwraps the block — drops its braces, splicing the trimmed statements
 * into the parent — which is always safe for a binding-free block. The canonical
 * pipeline reformats the result.
 *
 * ## Grammar-agnostic
 *
 * `RefShape.blockStmtKind` is the statement-block kind, `localDeclKinds` /
 * `functionKinds` the binding kinds that mark a real scope, `opaqueKinds` the
 * reification subtrees to skip, and `GrammarPlugin.controlFlowSupport` supplies the
 * block-container kinds. Any unset → no-op (an empty filter set just skips that
 * filter).
 */
@:nullSafety(Strict)
final class UnnecessaryBlock implements Check {

	public function new() {}

	public function id(): String {
		return 'unnecessary-block';
	}

	public function description(): String {
		return 'a bare { } statement block, with no binding of its own, that adds a needless scope';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return [];
		final shape: RefShape = plugin.refShape();
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		if (blockStmtKind == null) return [];
		final blockKinds: Array<String> = support.blockKinds();
		final bindingKinds: Array<String> = (shape.localDeclKinds ?? []).concat(shape.functionKinds ?? []);
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, tree, blockKinds, blockStmtKind, bindingKinds, opaqueKinds);
		}
		return violations;
	}

	/**
	 * Unwrap each flagged block. Re-parses `source`, indexes the statement blocks by
	 * start offset, and for a flagged block declaring no binding (the same gate `run`
	 * applied) replaces the block span with its trimmed inner source — the bytes
	 * between the braces — for the caller to canonicalize.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		if (blockStmtKind == null) return [];
		final bindingKinds: Array<String> = (shape.localDeclKinds ?? []).concat(shape.functionKinds ?? []);
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree == null) return [];
		final byFrom: Map<Int, QueryNode> = [];
		indexBlocks(tree, blockStmtKind, byFrom);
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final vSpan: Null<Span> = v.span;
			if (vSpan == null) continue;
			final block: Null<QueryNode> = byFrom[vSpan.from];
			if (block == null || declaresBinding(block, bindingKinds)) continue;
			final span: Null<Span> = block.span;
			if (span != null) edits.push({ span: span, text: StringTools.trim(source.substring(span.from + 1, span.to - 1)) });
		}
		return edits;
	}

	/**
	 * Walk `node`, skipping reification subtrees; flag each binding-free statement-
	 * block child of a block container.
	 */
	private static function walk(
		out: Array<Violation>, file: String, node: QueryNode, blockKinds: Array<String>, blockStmtKind: String,
		bindingKinds: Array<String>, opaqueKinds: Array<String>
	): Void {
		if (opaqueKinds.contains(node.kind)) return;
		if (blockKinds.contains(node.kind)) for (child in node.children) if (child.kind == blockStmtKind && !declaresBinding(
			child, bindingKinds
		)) {
			final span: Null<Span> = child.span;
			if (span != null) out.push({
				file: file,
				span: span,
				rule: 'unnecessary-block',
				severity: Severity.Info,
				message: 'redundant block — these statements need no extra { } scope'
			});
		}
		for (c in node.children) walk(out, file, c, blockKinds, blockStmtKind, bindingKinds, opaqueKinds);
	}

	/** Index every statement-block node in `node` by its span's start offset. */
	private static function indexBlocks(node: QueryNode, blockStmtKind: String, out: Map<Int, QueryNode>): Void {
		if (node.kind == blockStmtKind) {
			final span: Null<Span> = node.span;
			if (span != null) out[span.from] = node;
		}
		for (c in node.children) indexBlocks(c, blockStmtKind, out);
	}

	/** Whether `block` declares a binding directly (a `var` / `final` or a local function — a real scope to preserve). */
	private static function declaresBinding(block: QueryNode, bindingKinds: Array<String>): Bool {
		for (child in block.children) if (bindingKinds.contains(child.kind)) return true;
		return false;
	}

}

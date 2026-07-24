package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a bare `{ … }` statement block — one written directly in a statement-list
 * position (another block, or a `case` / `default` arm body) rather than as a
 * control-flow body — that declares no binding of its own, so it is a pure scope with
 * no effect. Purely structural; `Info`, with an unwrap autofix. A common AS3-to-Haxe
 * conversion artifact is `case X: { … }`.
 *
 * ## What is flagged
 *
 * A `blockStmtKind` node whose PARENT is itself a statement-list container — a block
 * container (`ControlFlowSupport.blockKinds()` — a function body, another statement
 * block, or a block expression) OR a `case` / `default` arm (`caseBranchKind` /
 * `defaultBranchKind`, whose body is a statement list too) — AND which declares no
 * binding directly (no `localDeclKinds` and no local-function `functionKinds` child).
 * The body of an `if` / loop / `try` is a `blockStmtKind` too, but its parent is the
 * control-flow node, not a container, so it is never flagged; a `case` PATTERN or
 * GUARD is never a `blockStmtKind`, so listing the branch as a container is exact. A
 * block that declares a local (a `var` / `final` or a local `function`) is a real
 * scope — unwrapping it could collide with, widen, or hoist a binding — so it is left
 * alone. A metadata-carrying block is structurally excluded — `@:m { … }` parses as a
 * metadata wrapper over a block EXPRESSION, never a bare `blockStmtKind` — so a leading
 * annotation is never lost. A metaprogramming-reification subtree (`opaqueKinds`) is
 * skipped wholesale: a block the macro emits is structural, not author noise.
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
 * reification subtrees to skip, `caseBranchKind` / `defaultBranchKind` the switch-arm
 * containers, and `GrammarPlugin.controlFlowSupport` supplies the block-container
 * kinds. Any unset → no-op (an empty filter set just skips that filter).
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
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return [];
		final containerKinds: Array<String> = support.blockKinds().concat(seams.caseBranchKinds);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null)
				walk(violations, entry.file, tree, containerKinds, seams.blockStmtKind, seams.bindingKinds, seams.opaqueKinds);
		}
		return violations;
	}

	/**
	 * Unwrap each flagged block. Re-parses `source`, indexes the statement blocks by
	 * span, and for a flagged block declaring no binding (the same gate `run`
	 * applied) replaces the block span with its trimmed inner source — the bytes
	 * between the braces — for the caller to canonicalize.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = resolveSeams(plugin);
		return seams == null
			? []
			: CheckScan.applyBySpan(
				plugin, source, violations, [seams.blockStmtKind], (node, span) -> declaresBinding(node, seams.bindingKinds) ? null : {
					span: span,
					text: StringTools.trim(source.substring(span.from + 1, span.to - 1))
				}
			);
	}

	/**
	 * Walk `node`, skipping reification subtrees; flag each binding-free statement-
	 * block child of a block container.
	 */
	private static function walk(
		out: Array<Violation>, file: String, node: QueryNode, containerKinds: Array<String>, blockStmtKind: String,
		bindingKinds: Array<String>, opaqueKinds: Array<String>
	): Void {
		if (opaqueKinds.contains(node.kind)) return;
		if (containerKinds.contains(node.kind)) for (child in node.children) if (
			child.kind == blockStmtKind && !declaresBinding(child, bindingKinds)
		) {
			final span: Null<Span> = child.span;
			if (span != null) out.push({
				file: file,
				span: span,
				rule: 'unnecessary-block',
				severity: Severity.Info,
				message: 'redundant block — these statements need no extra { } scope'
			});
		}
		for (c in node.children) walk(out, file, c, containerKinds, blockStmtKind, bindingKinds, opaqueKinds);
	}


	/** Whether `block` declares a binding directly (a `var` / `final` or a local function — a real scope to preserve). */
	private static function declaresBinding(block: QueryNode, bindingKinds: Array<String>): Bool {
		for (child in block.children) if (bindingKinds.contains(child.kind)) return true;
		return false;
	}


	/** Resolve the block-statement seam kind plus the binding / opaque kinds, or null when the block kind is unset. */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		if (blockStmtKind == null) return null;
		final bindingKinds: Array<String> = (shape.localDeclKinds ?? []).concat(shape.functionKinds ?? []);
		final caseBranchKinds: Array<String> = [for (k in [shape.caseBranchKind, shape.defaultBranchKind]) if (k != null) k];
		return {
			blockStmtKind: blockStmtKind,
			bindingKinds: bindingKinds,
			opaqueKinds: shape.opaqueKinds ?? [],
			caseBranchKinds: caseBranchKinds
		};
	}

}

/** The resolved seams `UnnecessaryBlock` reads in both `run` and `fix`; `ControlFlowSupport`/`blockKinds` are resolved separately since only `run` needs them. */
private typedef Seams = {
	final blockStmtKind: String;
	final bindingKinds: Array<String>;
	final opaqueKinds: Array<String>;
	final caseBranchKinds: Array<String>;
};

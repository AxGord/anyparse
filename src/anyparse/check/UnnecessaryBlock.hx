package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using StringTools;

/**
 * Flags a bare `{ … }` statement block — one written directly in a statement-list position (another block, or a
 * `case` / `default` arm body) rather than as a control-flow body — whose statements would read the same one
 * indent to the left, so the braces buy nothing. `Info`, with an unwrap autofix. A common AS3-to-Haxe conversion
 * artifact is `case X: { … }`; the other common source is this linter itself, whose always-true-`if` fixes used
 * to splice the body block whole.
 *
 * ## What is flagged
 *
 * A `blockStmtKind` node whose PARENT is itself a statement-list container — a block container
 * (`ControlFlowSupport.blockKinds()` — a function body, another statement block, or a block expression) OR a
 * `case` / `default` arm (`caseBranchKind` / `defaultBranchKind`, whose body is a statement list too) — and which
 * passes the three unwrap gates `harvest` documents: it must be the ONLY bare block of its container, hold at
 * most `CheckScan.BARE_BLOCK_MAX_STATEMENTS` statements, and bind no name already live in the frame it would
 * unwrap into.
 *
 * The body of an `if` / loop / `try` is a `blockStmtKind` too, but its parent is the control-flow node, not a
 * container, so it is never flagged; a `case` PATTERN or GUARD is never a `blockStmtKind`, so listing the branch
 * as a container is exact. A metadata-carrying block is structurally excluded — `@:m { … }` parses as a metadata
 * wrapper over a block EXPRESSION, never a bare `blockStmtKind` — so a leading annotation is never lost. A
 * metaprogramming-reification subtree (`opaqueKinds`) is skipped wholesale: a block the macro emits is
 * structural, not author noise.
 *
 * ## Autofix
 *
 * `--fix` unwraps the block — drops its braces, splicing the trimmed statements into the parent. The canonical
 * pipeline reformats the result.
 *
 * ## Grammar-agnostic
 *
 * `RefShape.blockStmtKind` is the statement-block kind, `caseBranchKind` / `defaultBranchKind` the switch-arm
 * containers, `opaqueKinds` the reification subtrees to skip, and `GrammarPlugin.controlFlowSupport` supplies the
 * block-container kinds. The scope model behind the collision gate is `ScopeFrames`, driven by
 * `RefShape.scopeKinds` plus the widened binding-kind set `ScopeFrames.bindingKinds` assembles. Any unset seam →
 * no-op.
 */
@:nullSafety(Strict)
final class UnnecessaryBlock implements Check {

	public function new() {}

	public function id(): String {
		return 'unnecessary-block';
	}

	public function description(): String {
		return 'a bare { } statement block that adds a scope its statements do not need';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final resolved: Null<Seams> = resolveSeams(plugin);
		if (resolved == null) return [];
		final seams: Seams = resolved;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			for (block in unwrappable(tree, seams)) {
				final span: Null<Span> = block.span;
				if (span != null) violations.push({
					file: entry.file,
					span: span,
					rule: 'unnecessary-block',
					severity: Severity.Info,
					message: 'redundant block — these statements need no extra { } scope'
				});
			}
		}
		return violations;
	}

	/**
	 * Unwrap each flagged block. Re-parses `source` and re-derives the unwrappable set under the same gate `run`
	 * applied — a fix must never trust a violation span alone, since a stale or hand-written violation could name a
	 * block whose bindings now collide — then replaces each approved block span with its trimmed inner source, the
	 * bytes between the braces, for the caller to canonicalize. Comments anywhere inside the braces sit in that
	 * slice and survive verbatim.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final resolved: Null<Seams> = resolveSeams(plugin);
		if (resolved == null) return [];
		final seams: Seams = resolved;
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final approved: Map<String, Bool> = [];
		for (block in unwrappable(tree, seams)) {
			final span: Null<Span> = block.span;
			if (span != null) approved['${span.from}:${span.to}'] = true;
		}
		return CheckScan.applyBySpan(
			plugin, source, violations, [seams.blockStmtKind], (node, span) -> approved['${span.from}:${span.to}'] != true ? null : {
				span: span,
				text: source.substring(span.from + 1, span.to - 1).trim()
			}
		);
	}

	/**
	 * Walk `node`, skipping reification subtrees; harvest the unwrappable blocks of every statement-list container.
	 */
	private static function walk(node: QueryNode, seams: Seams, frames: Map<QueryNode, Array<String>>, out: Array<QueryNode>): Void {
		if (seams.opaqueKinds.contains(node.kind)) return;
		if (seams.containerKinds.contains(node.kind)) harvest(node, seams, frames[node] ?? [], out);
		for (c in node.children) walk(c, seams, frames, out);
	}

	/**
	 * Resolve the block-statement seam kind, the statement-list container kinds and the scope-frame seams — or null
	 * when the block kind or `ControlFlowSupport` is unset, which makes the check a no-op.
	 *
	 * `localDeclKinds` is deliberately WIDER than `RefShape.localDeclKinds`: it is every statement kind that BINDS a
	 * name in its enclosing frame, and it feeds BOTH sides of the gate — the block's own top-level bindings and the
	 * names `ScopeFrames` collects for the target frame. A kind counted on one side and not the other is a silent
	 * hole; `LocalInlineFnStmt`, the form this codebase's Haxe style prescribes for a local helper, was exactly
	 * that.
	 */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (blockStmtKind == null || support == null) return null;
		final blockKinds: Array<String> = support.blockKinds();
		final caseBranchKinds: Array<String> = [for (k in [shape.caseBranchKind, shape.defaultBranchKind]) if (k != null) k];
		return {
			blockStmtKind: blockStmtKind,
			opaqueKinds: shape.opaqueKinds ?? [],
			containerKinds: blockKinds.concat(caseBranchKinds),
			blockKinds: blockKinds,
			scopeKinds: shape.scopeKinds,
			functionKinds: shape.functionKinds ?? [],
			localDeclKinds: ScopeFrames.bindingKinds(shape),
			condKind: shape.conditionalMemberKind
		};
	}

	/** Every block of `root` that unwraps cleanly into its container, in document order. */
	private static function unwrappable(root: QueryNode, seams: Seams): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		walk(root, seams, ScopeFrames.frameIndex(root, seams), out);
		return out;
	}

	/**
	 * Append `container`'s bare block when it unwraps cleanly into it, where `scopeNames` is the frame it would
	 * land in. Three gates.
	 *
	 * The LONE gate refuses as soon as a container holds a SECOND bare block: a run of them is a sectioning
	 * device — the author is delimiting phases of a long body — and flattening one of a set destroys the
	 * scheme. One block among ordinary statements delimits nothing.
	 *
	 * The WEIGHT gate refuses a block of more than `MAX_STATEMENTS` top-level statements: past a handful the
	 * braces read as a section marker rather than as noise around a couple of lines.
	 *
	 * The SCOPE gate refuses a block whose top-level binding carries a name already live in the target frame —
	 * see `ScopeFrames.collidesWithScope` for why refusing is the only protection there. The frame is read at the
	 * CONTAINER, not at the block: a block is itself a scope (`RefShape.scopeKinds`), so its own bindings are
	 * absent from the container's frame and a candidate can never collide with itself.
	 */
	private static function harvest(container: QueryNode, seams: Seams, scopeNames: Array<String>, out: Array<QueryNode>): Void {
		var only: Null<QueryNode> = null;
		for (child in container.children) if (child.kind == seams.blockStmtKind && child.span != null) {
			if (only != null) return;
			only = child;
		}
		final block: Null<QueryNode> = only;
		if (
			block != null && block.children.length <= CheckScan.BARE_BLOCK_MAX_STATEMENTS
			&& !ScopeFrames.collidesWithScope(block.children, seams.localDeclKinds, scopeNames)
		)
			out.push(block);
	}

}

/**
 * The resolved seams `UnnecessaryBlock` reads in both `run` and `fix`. The frame fields unify structurally with `ScopeFrames.FrameSeams`, so the value is passed to `ScopeFrames` unconverted.
 */
private typedef Seams = {
	final blockStmtKind: String;
	final opaqueKinds: Array<String>;
	final containerKinds: Array<String>;
	final blockKinds: Array<String>;
	final scopeKinds: Array<String>;
	final functionKinds: Array<String>;
	final localDeclKinds: Array<String>;
	final condKind: Null<String>;
};

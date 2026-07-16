package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags statements made unreachable by a preceding unconditional exit — a
 * `return` / `throw` / `break` / `continue` followed by more statements in the
 * same block. Purely structural (no type information needed), so it holds even
 * without a type-checker. `Warning`.
 *
 * ## Grammar-agnostic
 *
 * Block detection and terminal-statement detection live behind
 * `ControlFlowSupport` (the plugin seam): `blockKinds()` names the
 * statement-sequence nodes and `isTerminal(node)` decides whether a statement
 * exits its block. A grammar without the seam (binary formats) makes the check
 * a no-op.
 *
 * ## What is flagged
 *
 * Within each block the FIRST statement after the first terminal sibling is
 * flagged once (a single `Warning` per dead run, not one per dead line). A
 * terminal nested inside a child statement (a `return` inside an `if` body) is
 * not a direct sibling, so it does not make the outer block's following
 * statements unreachable — only a terminal that IS a direct sibling does.
 *
 * ## Autofix
 *
 * Unreachable code never executes, so `fix` deletes the whole dead run — every
 * statement from the first unreachable one to the block's end — as one
 * whole-line deletion (`lineExtendedSpan`), so the batched `canonicalize` leaves
 * no blank residue.
 */
@:nullSafety(Strict)
final class DeadCode implements Check {

	public function new() {}

	public function id(): String {
		return 'dead-code';
	}

	public function description(): String {
		return 'unreachable code after an unconditional return / throw / break / continue';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, tree, support);
		}
		return violations;
	}

	/**
	 * Delete each flagged dead run. Unreachable code never executes, so removing
	 * every statement from the first unreachable one to the end of its block is
	 * always safe. One whole-line deletion per run; needs `ControlFlowSupport`
	 * (unset makes the check report-only).
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];

		final flagged: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push('${span.from}:${span.to}');
		}
		final edits: Array<{ span: Span, text: String }> = [];
		collectDeletions(tree, source, support, flagged, edits);
		// A nested dead run sits inside an outer one; keep only the outer deletion.
		return RefactorSupport.dropContainedEdits(edits);
	}

	/**
	 * Walk `node`; at each block flag the first statement following the first
	 * terminal sibling. The whole tree is walked so nested blocks are reached.
	 */
	private static function walk(out: Array<Violation>, file: String, node: QueryNode, support: ControlFlowSupport): Void {
		if (support.blockKinds().contains(node.kind)) flagBlock(out, file, node, support);
		for (c in node.children) walk(out, file, c, support);
	}

	/**
	 * Emit one `Warning` on the first child after the first terminal direct
	 * child of `block`, when one follows. Bails when that child has no span.
	 */
	private static function flagBlock(out: Array<Violation>, file: String, block: QueryNode, support: ControlFlowSupport): Void {
		final kids: Array<QueryNode> = block.children;
		for (i in 0...kids.length) if (support.isTerminal(kids[i])) {
			if (i + 1 < kids.length) {
				final span: Null<Span> = kids[i + 1].span;
				if (span != null) out.push({
					file: file,
					span: span,
					rule: 'dead-code',
					severity: Severity.Warning,
					message: 'unreachable code'
				});
			}
			return;
		}
	}

	/**
	 * Walk `node`; in each block whose first dead statement is flagged, emit one
	 * whole-line deletion spanning the entire dead run (the first unreachable
	 * statement through the block's last child).
	 */
	private static function collectDeletions(
		node: QueryNode, source: String, support: ControlFlowSupport, flagged: Array<String>, edits: Array<{ span: Span, text: String }>
	): Void {
		if (support.blockKinds().contains(node.kind)) deleteRun(node, source, support, flagged, edits);
		for (c in node.children) collectDeletions(c, source, support, flagged, edits);
	}

	/**
	 * Mirror `flagBlock`: find the first terminal direct child; if a statement
	 * follows and its span is the flagged one, delete from it to the block's last
	 * child as a single whole-line edit.
	 */
	private static function deleteRun(
		block: QueryNode, source: String, support: ControlFlowSupport, flagged: Array<String>, edits: Array<{ span: Span, text: String }>
	): Void {
		final kids: Array<QueryNode> = block.children;
		for (i in 0...kids.length) if (support.isTerminal(kids[i])) {
			if (i + 1 < kids.length) {
				final firstDead: Null<Span> = kids[i + 1].span;
				final lastDead: Null<Span> = kids[kids.length - 1].span;
				if (firstDead != null && lastDead != null && flagged.contains('${firstDead.from}:${firstDead.to}'))
					edits.push({ span: RefactorSupport.lineExtendedSpan(source, new Span(firstDead.from, lastDead.to)), text: '' });
			}
			return;
		}
	}

}

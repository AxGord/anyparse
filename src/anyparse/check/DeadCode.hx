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
 * Flags statements made unreachable by a preceding unconditional exit — a
 * `return` / `throw` / `break` / `continue` followed by more statements in the
 * same block. Purely structural (no type information needed), so it holds even
 * without a type-checker. Report-only: the dead code is provably removable, but
 * this slice surfaces it as a `Warning` without an autofix.
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
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, tree, support);
		}
		return violations;
	}

	/** Dead-code has no autofix in this slice — report-only. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
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

}

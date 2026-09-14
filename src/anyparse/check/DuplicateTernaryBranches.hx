package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a ternary whose two branches are identical — `cond ? x : x` — which always
 * evaluates to `x` regardless of `cond`, so the condition is dead and the branches
 * were probably meant to differ. `Warning`. The autofix collapses it to the branch
 * (`cond ? x : x` → `x`) only when `cond` is side-effect-free; with a side-effecting
 * condition (`f() ? x : x`) the finding is report-only, since dropping `cond` would
 * drop its side effect.
 *
 * ## Grammar-agnostic
 *
 * The ternary kind comes from `RefShape.ternaryKind` (unset → no-op); branch
 * equality is the trimmed-source comparison of `RefactorSupport.sameSource`, and
 * the side-effect gate is `RefactorSupport.isSideEffectFree`. The outermost
 * matching ternary is flagged and not descended into (a nested identical-branch
 * ternary is subsumed by the single fix).
 */
@:nullSafety(Strict)
final class DuplicateTernaryBranches implements Check {

	/** A complete ternary node has children [cond, then, else]. */
	private static inline final TERNARY_CHILD_COUNT: Int = 3;

	public function new() {}

	public function id(): String {
		return 'duplicate-ternary-branches';
	}

	public function description(): String {
		return 'a ternary whose then- and else-branches are identical (cond ? x : x)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return RunScan.collectWith(
			files, plugin, plugin.refShape().ternaryKind,
			(entry, tree, ternaryKind, violations) -> walk(violations, entry.file, entry.source, tree, ternaryKind)
		);
	}

	/** Collapse each flagged ternary to its (identical) branch when the condition is pure. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {

		return RunScan.editsWith(plugin, source, plugin.refShape().ternaryKind, (tree, ternaryKind) -> {
			final nodeByKey: Map<String, QueryNode> = [];
			indexTernaries(tree, ternaryKind, nodeByKey);

			final edits: Array<{ span: Span, text: String }> = [];
			for (v in violations) {
				final span: Null<Span> = v.span;
				if (span == null) continue;
				final node: Null<QueryNode> = nodeByKey['${span.from}:${span.to}'];
				if (node == null || node.children.length != TERNARY_CHILD_COUNT) continue;
				// Only safe to drop the condition when evaluating it has no side effect.
				if (!MemberKinds.isSideEffectFree(node.children[0], plugin.refShape())) continue;
				final branchSpan: Null<Span> = node.children[1].span;
				if (branchSpan == null) continue;
				edits.push({ span: span, text: source.substring(branchSpan.from, branchSpan.to) });
			}
			return edits;
		});
	}

	private static function walk(out: Array<Violation>, file: String, source: String, node: QueryNode, ternaryKind: String): Void {
		if (
			node.kind == ternaryKind && node.children.length == TERNARY_CHILD_COUNT
			&& MemberKinds.sameSource(node.children[1], node.children[2], source)
		) {
			final span: Null<Span> = node.span;
			if (span != null) {
				out.push({
					file: file,
					span: span,
					rule: 'duplicate-ternary-branches',
					severity: Severity.Warning,
					message: 'both branches of this ternary are identical'
				});
				return;
			}
		}
		for (c in node.children) walk(out, file, source, c, ternaryKind);
	}

	/** Index every ternary node by its `from:to` span key. */
	private static function indexTernaries(node: QueryNode, ternaryKind: String, out: Map<String, QueryNode>): Void {
		if (node.kind == ternaryKind) {
			final span: Null<Span> = node.span;
			if (span != null) out['${span.from}:${span.to}'] = node;
		}
		for (c in node.children) indexTernaries(c, ternaryKind, out);
	}

}

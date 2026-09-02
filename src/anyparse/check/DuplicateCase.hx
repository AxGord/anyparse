package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.CondBranchPath;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * Flags a duplicated switch case — a second branch whose pattern repeats an
 * earlier branch's in the same switch, making it dead. Purely structural.
 * `fix` deletes the later (dead) arm. Guarded branches (`case x if (cond):`) are skipped: two branches
 * with the same pattern but different guards are legitimately distinct, and
 * isolating the guard reliably needs more than the pattern node.
 *
 * ## Grammar-agnostic
 *
 * The case-branch kind comes from `RefShape.caseBranchKind` (unset → no-op). A
 * branch's pattern is its first child; a guard, when present, sits between the
 * pattern and the body, introduced by `if` in the intervening source.
 */
@:nullSafety(Strict)
final class DuplicateCase implements Check {

	private static final GUARD: EReg = ~/\bif\b/;

	public function new() {}

	public function id(): String {
		return 'duplicate-case';
	}

	public function description(): String {
		return 'a switch case whose pattern repeats an earlier case in the same switch';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final declared: Null<String> = shape.caseBranchKind;
		if (declared == null) return [];
		final caseBranchKind: String = declared;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null)
				walk(
					violations, entry.file, entry.source, tree,
					{ caseBranchKind: caseBranchKind, conditionalKind: shape.conditionalMemberKind },
					CondBranchPath.scan(entry.source, shape, plugin.lexicalRegions(entry.source))
				);
		}
		return violations;
	}

	/** `fix` deletes the later (dead) duplicate arm; the writer round-trip re-canonicalises the switch. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final caseBranchKind: Null<String> = plugin.refShape().caseBranchKind;
		return caseBranchKind == null
			? []
			: CheckScan.applyBySpan(
				plugin, source, violations, [caseBranchKind], (_, span) -> ({ span: CheckScan.lineDeletionSpan(source, span), text: '' })
			);
	}

	/**
	 * Walk `node`; among its DIRECT case-branch children flag a branch whose
	 * pattern source repeats an earlier sibling's. The whole tree is walked so
	 * nested switches are reached.
	 */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, seams: CaseSeams, branches: CondBranchIndex
	): Void {
		// A `#if` region inside a case list projects as ONE child of the switch whose own
		// children are the case branches of EVERY branch of the region, flattened. So the arms
		// a switch really offers are its direct case children PLUS those, and comparing only
		// direct children misses a label repeated across the boundary while comparing a
		// region's children as neighbours invents one across its branches. `CondBranchPath`
		// settles both: the arms are gathered together, and two of them are compared only when
		// no region puts them in different branches.
		if (node.kind != seams.conditionalKind) compareArms(out, file, source, gatherArms(node, seams), branches);
		for (child in node.children) walk(out, file, source, child, seams, branches);
	}

	/**
	 * The case arms `node` offers, in source order: its direct case-branch children, plus those
	 * of any conditional region among them (recursively, since a region may nest another).
	 */
	private static function gatherArms(node: QueryNode, seams: CaseSeams): Array<QueryNode> {
		final arms: Array<QueryNode> = [];
		for (child in node.children) {
			if (child.kind == seams.caseBranchKind)
				arms.push(child)
			else if (child.kind == seams.conditionalKind)
				for (arm in gatherArms(child, seams)) arms.push(arm);
		}
		return arms;
	}

	/** Report every arm whose pattern repeats an EARLIER comparable one — same pattern text, no region telling them apart. */
	private static function compareArms(
		out: Array<Violation>, file: String, source: String, arms: Array<QueryNode>, branches: CondBranchIndex
	): Void {
		final seen: Array<{ pattern: String, path: Array<CondFrame> }> = [];
		for (branch in arms) {
			final found: Null<String> = patternSource(branch, source);
			final at: Null<Span> = branch.span;
			if (found == null || at == null) continue;
			final pattern: String = found;
			final span: Span = at;
			final path: Array<CondFrame> = CondBranchPath.pathAt(branches, span.from);
			if (seen.exists(s -> s.pattern == pattern && CondBranchPath.comparable(s.path, path)))
				out.push({
					file: file,
					span: span,
					rule: 'duplicate-case',
					severity: Severity.Warning,
					message: 'duplicate case label'
				})
			else
				seen.push({ pattern: pattern, path: path });
		}
	}

	/**
	 * The trimmed source of `branch`'s pattern (its first child), or null when the
	 * branch is guarded (an `if` appears between the pattern and the next child) or
	 * has no spanned pattern — both are skipped rather than compared.
	 */
	private static function patternSource(branch: QueryNode, source: String): Null<String> {
		final kids: Array<QueryNode> = branch.children;
		if (kids.length == 0) return null;
		final patternSpan: Null<Span> = kids[0].span;
		if (patternSpan == null) return null;
		if (kids.length >= 2) {
			final nextSpan: Null<Span> = kids[1].span;
			if (nextSpan != null && GUARD.match(source.substring(patternSpan.to, nextSpan.from))) return null;
		}
		return source.substring(patternSpan.from, patternSpan.to).trim();
	}

}

/** The two kinds `duplicate-case` walks by: a case branch, and the conditional region whose branches are alternatives. */
private typedef CaseSeams = {
	final caseBranchKind: String;
	final conditionalKind: Null<String>;
};

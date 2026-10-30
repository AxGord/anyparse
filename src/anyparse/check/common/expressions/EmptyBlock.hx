package anyparse.check.common.expressions;

import anyparse.check.Check.FixEdit;
import anyparse.query.CanonicalEdit;
import anyparse.query.ElementSpan;
import anyparse.query.MemberKinds;
import anyparse.query.ParseGate;
import anyparse.query.ShapeVocab;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;

/**
 * Flags an empty control-flow block — an `if` / `else` / `while` / `for` /
 * `try` / `catch` body written as `{}` with no statements: a forgotten
 * implementation, or an empty `catch` that silently swallows an error. Purely
 * structural (no type information needed), so it holds even without a
 * type-checker. Autofixable in part — `--fix` removes the provably-safe subset
 * (an empty `else {}`, and an empty no-else `if (cond) {}` with a
 * side-effect-free condition); an empty loop, `try`, or `catch` body stays a
 * report-only `Warning`, and each finding the fix leaves alone names its gate
 * (`Violation.declineReason`).
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
 * Nor is the body of a DRAIN loop: a condition loop (`ShapeVocab.conditionLoopKinds`)
 * whose condition is not side-effect-free — `while (gl.getError() != 0) {}` does its
 * work in the condition, so the empty body is the idiom. A `for` gets no such pass.
 */
@:nullSafety(Strict)
final class EmptyBlock extends RuleBase {

	/** An if node with both branches has children [cond, then, else]. */
	private static inline final IF_WITH_ELSE_CHILD_COUNT: Int = 3;

	private static inline final DECLINE_LOOP: String = 'a loop body: removing it removes the loop';
	private static inline final DECLINE_TRY: String = 'a try / catch body: the construct needs it';
	private static inline final DECLINE_SIDE_EFFECT: String = 'the if condition may have a side effect';
	private static inline final DECLINE_BRANCH_BODY: String = 'the if is a single-statement branch body';
	private static inline final DECLINE_THEN_WITH_ELSE: String = 'an empty then-branch with an else needs the condition inverted';
	private static inline final DECLINE_OTHER: String = 'only an empty else and an empty no-else if are removed';

	public function new() {
		super(
			'empty-block', 'an empty control-flow block ({} with no statements) for an if / else / loop / try / catch',
			RuleCategory.Expressions
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final conditionLoops: Array<String> = ShapeVocab.conditionLoopKinds(shape);
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			// A project checkstyle `EmptyBlock.option` of `empty` (allow empty blocks) disables this check.
			if (plugin.checkOverrides(entry.file)?.emptyBlockEnabled == false) continue;
			final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, entry.source);
			if (tree != null) walk({
				out: violations,
				file: entry.file,
				source: entry.source,
				flagKinds: support.emptyFlagKinds(),
				conditionLoops: conditionLoops,
				shape: shape
			}, tree, null);
		}
		return violations;
	}

	/**
	 * Delete the provably-safe subset of empty blocks: an empty `else {}` (the
	 * ` else {}` is cut, keeping the `if` and its non-empty then-branch) and an
	 * empty no-else `if (cond) {}` whose condition is side-effect-free (the whole
	 * `if` is dropped). The rest stays report-only — an empty loop body or an
	 * empty `if` with a side-effecting condition would lose that evaluation, and
	 * an empty `catch {}` cannot be removed (a `try` needs its catch) — and each
	 * such finding carries the gate that kept it as its `declineReason`.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {

		// Statement-list kinds: a no-else `if (cond) {}` is safe to DELETE only
		// when it sits in one of these; as a single-statement branch body its
		// removal would strand the enclosing branch. Absent seam -> never delete.
		return RunScan.edits(plugin, source, tree -> {
			final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
			final blockKinds: Array<String> = support != null ? support.blockKinds() : [];
			final flagged: Map<String, Violation> = RunScan.findingsBySpan(violations);
			final edits: Array<FixEdit> = [];
			collectEmptyFixes(tree, null, null, source, blockKinds, flagged, edits, plugin.refShape());
			return CanonicalEdit.dropContainedEdits(edits);
		});
	}

	/** Walk `node` (a child of `parent`), flagging every empty control-flow block reached. */
	private static function walk(scan: EmptyScan, node: QueryNode, parent: Null<QueryNode>): Void {
		final span: Null<Span> = node.span;
		if (
			span != null
			&& node.children.length == 0
			&& scan.flagKinds.contains(node.kind)
			&& SourceText.isBlankSpan(span, scan.source)
			&& !isDrainLoopBody(node, parent, scan)
		) scan.out.push({
			file: scan.file,
			span: span,
			rule: 'empty-block',
			severity: Severity.Warning,
			message: 'empty block'
		});
		for (c in node.children) walk(scan, c, node);
	}

	/**
	 * Whether `node` is the body of a condition loop whose condition is not
	 * side-effect-free — `while (gl.getError() != 0) {}`, `while (i++ < n) {}`:
	 * the loop's work is its condition, so an empty body is what it means.
	 */
	private static function isDrainLoopBody(node: QueryNode, parent: Null<QueryNode>, scan: EmptyScan): Bool {
		return parent != null
			&& scan.conditionLoops.contains(parent.kind)
			&& parent.children.exists(c -> c != node && !MemberKinds.isSideEffectFree(c, scan.shape));
	}

	/**
	 * Walk `node` with its `parent` and `grandparent`, collecting the safe deletion
	 * of each flagged empty block, or writing why it has none onto its finding.
	 */
	private static function collectEmptyFixes(
		node: QueryNode, parent: Null<QueryNode>, grandparent: Null<QueryNode>, source: String, blockKinds: Array<String>,
		flagged: Map<String, Violation>, edits: Array<{ span: Span, text: String }>, shape: RefShape
	): Void {
		final span: Null<Span> = node.span;
		final finding: Null<Violation> = span != null ? flagged['${span.from}:${span.to}'] : null;
		if (finding != null && parent != null) switch emptyBlockFix(node, parent, grandparent, source, blockKinds, shape) {
			case Remove(edit):
				edits.push(edit);
			case Keep(reason):
				finding.declineReason = reason;
		}
		for (c in node.children) collectEmptyFixes(c, node, parent, source, blockKinds, flagged, edits, shape);
	}

	/**
	 * What the fix does with a flagged empty `BlockStmt` under `parent`. An empty
	 * `else` branch (the parent `if` has a then AND this else) cuts ` else {}`; an
	 * empty no-else then-branch with a side-effect-free condition drops the whole
	 * `if` — but only when that `if` is itself a statement-list member
	 * (`grandparent` is in `blockKinds`). As a single-statement branch body,
	 * dropping it would strand the enclosing branch (a dangling `if` / `else`), so
	 * it stays report-only. Every other block is kept, with the gate that kept it.
	 */
	private static function emptyBlockFix(
		node: QueryNode, parent: QueryNode, grandparent: Null<QueryNode>, source: String, blockKinds: Array<String>, shape: RefShape
	): EmptyFix {
		if (parent.kind != 'IfStmt') return Keep(keptBodyReason(parent, shape));
		final nspan: Null<Span> = node.span;
		if (nspan == null) return Keep(DECLINE_OTHER);
		final kids: Array<QueryNode> = parent.children;
		// Empty `else {}` — this node is the else branch (then + else both present).
		if (kids.length >= IF_WITH_ELSE_CHILD_COUNT && kids[2] == node) {
			final thenSpan: Null<Span> = kids[1].span;
			return thenSpan == null
				? Keep(DECLINE_OTHER)
				: Remove({ span: ElementSpan.lineExtendedSpan(source, new Span(thenSpan.to, nspan.to)), text: '' });
		}
		// Empty no-else `if (cond) {}` with a side-effect-free condition — safe to
		// drop only when the `if` is a statement-list member, not a branch body.
		if (kids.length != 2 || kids[1] != node) return Keep(DECLINE_THEN_WITH_ELSE);
		if (!MemberKinds.isSideEffectFree(kids[0], shape)) return Keep(DECLINE_SIDE_EFFECT);
		if (grandparent == null || !blockKinds.contains(grandparent.kind)) return Keep(DECLINE_BRANCH_BODY);
		final pspan: Null<Span> = parent.span;
		return pspan == null ? Keep(DECLINE_OTHER) : Remove({ span: ElementSpan.lineExtendedSpan(source, pspan), text: '' });
	}

	/** Why an empty block that is not an `if` branch is kept: a loop body, a `try` / `catch` body, or neither. */
	private static function keptBodyReason(parent: QueryNode, shape: RefShape): String {
		return if (ShapeVocab.loopKinds(shape).contains(parent.kind))
			DECLINE_LOOP
		else if (ShapeVocab.tryKinds(shape).contains(parent.kind) || parent.kind == shape.catchClauseKind)
			DECLINE_TRY
		else
			DECLINE_OTHER;
	}

}

/** The per-run context of the empty-block walk: where findings go, and the kinds it tests nodes against. */
private typedef EmptyScan = {
	var out: Array<Violation>;
	var file: String;
	var source: String;
	var flagKinds: Array<String>;
	var conditionLoops: Array<String>;
	var shape: RefShape;
}

/** What the fix does with one flagged empty block: the deletion, or the gate that kept it. */
private enum EmptyFix {
	Remove(edit: FixEdit);
	Keep(reason: String);
}

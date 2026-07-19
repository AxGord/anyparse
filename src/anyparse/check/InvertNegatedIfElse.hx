package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags an `if` STATEMENT whose condition's TOP-LEVEL node is a logical NOT and which
 * has an `else` branch — `if (!c) A else B`. Inverting reads better as `if (c) B else A`:
 * drop the leading `!` and SWAP the two branches. A pure branch swap is an EXACT
 * complement of the negation, so it is semantics-safe under every value including `NaN`
 * (unlike a De Morgan condition rewrite, which is not). `Severity.Info`; `fix` performs
 * the inversion, moving each branch's source slot verbatim so braces / formatting /
 * comments travel with their branch.
 *
 * ## What is flagged
 *
 * Only a literal top-level `!` (`RefShape.notKind`) — a `!=` comparison is a different
 * kind and is never touched. Outer parentheses around the condition are unwrapped via
 * `RefShape.parenKind` (`if ((!c))` still counts). An `else` branch that is ITSELF an
 * `if` (an else-if chain) is skipped — swapping would restructure the chain rather than
 * simply invert. A no-`else` `if` is skipped (there is nothing to swap into). A comment
 * inside the condition that the rebuilt condition would drop leaves the finding
 * unreported — the swap is only offered when it loses nothing.
 *
 * ## Chaining with `comparison-to-boolean`
 *
 * `comparison-to-boolean` turns `x == false` into `!x`; this rule then removes that `!`
 * by swapping the branches — a multi-pass `--fix` converges the two into `if (x) B else A`.
 *
 * ## Autofix
 *
 * Three non-overlapping edits per finding: the condition span is replaced by the positive
 * condition (the not's operand source, unwrapping a redundant paren AROUND that operand —
 * always precedence-safe, since the operand becomes the whole `if`-parens-delimited
 * condition), and the then / else branch spans are swapped verbatim. The walk STOPS at a
 * flagged `if` (it does not descend into the swapped branches), so a nested invertible
 * `if-else` surfaces on a later pass and the per-pass edits never overlap. Unset
 * `ifStatementKinds` or `notKind` makes the check a no-op.
 */
@:nullSafety(Strict)
final class InvertNegatedIfElse implements Check {

	/** An if node with an else branch has children [cond, then, else]. */
	private static inline final IF_WITH_ELSE_CHILD_COUNT: Int = 3;

	public function new() {}

	public function id(): String {
		return 'invert-negated-if-else';
	}

	public function description(): String {
		return 'an if with a top-level negated condition and an else — invert the condition and swap the branches';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, tree, entry.source, seams);
		}
		return violations;
	}

	/**
	 * Invert each flagged `if`: replace its condition with the positive form and swap the
	 * then / else branch source. The flagged `if` is recovered by span; a re-validation
	 * (top-level not, non-`if` else, no dropped condition comment) guards the independent
	 * `fix` parse. Unset seams make `fix` a no-op.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final byKey: Map<String, QueryNode> = [];
		RefactorSupport.indexNodesByKind(tree, seams.ifKinds, byKey);
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final vspan: Null<Span> = v.span;
			if (vspan == null) continue;
			final ifNode: Null<QueryNode> = byKey['${vspan.from}:${vspan.to}'];
			if (ifNode != null) inversionEdits(ifNode, source, seams, edits);
		}
		return edits;
	}

	/**
	 * Walk `node`; flag an `if` STATEMENT with an `else` whose condition's top-level node
	 * (after unwrapping outer parens) is a logical not, then STOP descending into it — a
	 * nested invertible `if-else` is found on a re-run, keeping per-pass edits non-overlapping.
	 */
	private static function walk(out: Array<Violation>, file: String, node: QueryNode, source: String, seams: Seams): Void {
		if (seams.ifKinds.contains(node.kind) && node.children.length == IF_WITH_ELSE_CHILD_COUNT && isInvertible(node, source, seams)) {
			final span: Null<Span> = node.span;
			if (span != null) {
				out.push({
					file: file,
					span: span,
					rule: 'invert-negated-if-else',
					severity: Severity.Info,
					message: 'this negated if-else can be inverted — drop the ! and swap the branches'
				});
				return;
			}
		}
		for (c in node.children) walk(out, file, c, source, seams);
	}

	/**
	 * Whether `ifNode` is a swap candidate: its condition's top-level node (outer parens
	 * unwrapped) is a not, its `else` branch is not itself an `if`, and no comment in the
	 * condition span would be dropped by the rebuild.
	 */
	private static function isInvertible(ifNode: QueryNode, source: String, seams: Seams): Bool {
		final cond: QueryNode = ifNode.children[0];
		if (unwrapParens(cond, seams.parenKind).kind != seams.notKind) return false;
		if (seams.ifKinds.contains(ifNode.children[2].kind)) return false;
		final condSpan: Null<Span> = cond.span;
		return condSpan != null && !CheckScan.hasCommentMarker(source, condSpan.from, condSpan.to);
	}

	/**
	 * Push the three inversion edits for one flagged `if` (or nothing when it fails a
	 * re-validation or lacks the spans): condition replaced by the positive form, then /
	 * else branch source swapped.
	 */
	private static function inversionEdits(
		ifNode: QueryNode, source: String, seams: Seams, edits: Array<{ span: Span, text: String }>
	): Void {
		if (ifNode.children.length < IF_WITH_ELSE_CHILD_COUNT || !isInvertible(ifNode, source, seams)) return;
		final cond: QueryNode = ifNode.children[0];
		final thenBranch: QueryNode = ifNode.children[1];
		final elseBranch: QueryNode = ifNode.children[2];
		final notNode: QueryNode = unwrapParens(cond, seams.parenKind);
		if (notNode.children.length != 1) return;
		final condSpan: Null<Span> = cond.span;
		final thenSpan: Null<Span> = thenBranch.span;
		final elseSpan: Null<Span> = elseBranch.span;
		final positive: Null<String> = positiveConditionText(notNode.children[0], source, seams.parenKind);
		if (condSpan == null || thenSpan == null || elseSpan == null || positive == null) return;
		edits.push({ span: condSpan, text: positive });
		edits.push({ span: thenSpan, text: source.substring(elseSpan.from, elseSpan.to) });
		edits.push({ span: elseSpan, text: source.substring(thenSpan.from, thenSpan.to) });
	}

	/**
	 * The positive-condition source for the not's `operand`: its own source, but a single
	 * redundant paren AROUND the whole operand is unwrapped — the operand becomes the entire
	 * `if`-parens-delimited condition, so dropping that paren is always precedence-safe
	 * (`!(a && b)` becomes `a && b`). Null when the kept node has no span.
	 */
	private static function positiveConditionText(operand: QueryNode, source: String, parenKind: Null<String>): Null<String> {
		final kept: QueryNode = parenKind != null && operand.kind == parenKind && operand.children.length == 1
			? operand.children[0]
			: operand;
		final span: Null<Span> = kept.span;
		return span == null ? null : source.substring(span.from, span.to);
	}

	/** Unwrap single-child paren layers to reach the wrapped node (no-op when `parenKind` is unset). */
	private static function unwrapParens(node: QueryNode, parenKind: Null<String>): QueryNode {
		var n: QueryNode = node;
		while (parenKind != null && n.kind == parenKind && n.children.length == 1) n = n.children[0];
		return n;
	}

	/** Resolve the if / not / paren seam kinds, or null when a required piece is unset. */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		final notKind: Null<String> = shape.notKind;
		if (ifKinds.length == 0 || notKind == null) return null;
		final parenKind: Null<String> = shape.parenKind;
		return { ifKinds: ifKinds, notKind: notKind, parenKind: parenKind };
	}

}

/** The resolved seams `InvertNegatedIfElse` reads in both `run` and `fix`. */
private typedef Seams = {
	final ifKinds: Array<String>;
	final notKind: String;
	final parenKind: Null<String>;
};

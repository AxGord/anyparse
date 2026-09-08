package anyparse.check;

import anyparse.check.Check.NoAutofix;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a binary operator whose two operands are textually identical — `a == a`,
 * `a != a`, `a < a`, `a && a`, `a || a` and the like (SonarLint S1764). Almost
 * always a bug: a typo, or a leftover from an edit. Purely structural, so it
 * holds without type information; report-only (`fix` yields no edits).
 *
 * ## Grammar-agnostic
 *
 * The suspicious operator kinds come from `RefShape.comparisonKinds` (unset →
 * no-op). An operand containing a call (`RefShape.callKind`) is EXCLUDED:
 * `g() == g()` may legitimately compare two different results, so only
 * side-effect-free identical operands are flagged.
 */
@:nullSafety(Strict)
final class IdenticalOperands implements Check implements NoAutofix {

	public function new() {}

	public function id(): String {
		return 'identical-operands';
	}

	public function description(): String {
		return 'a binary operator (==, !=, <, &&, …) whose two operands are identical';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final comparisonKinds: Array<String> = shape.comparisonKinds ?? [];
		if (comparisonKinds.length == 0) return [];
		final callKind: Null<String> = shape.callKind;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, entry.source, tree, comparisonKinds, callKind);
		}
		return violations;
	}

	/**
	 * Report-only — see `noAutofixReason`.
	 *
	 * A collapse is EXPRESSIBLE for the `&&` / `||` half of `comparisonKinds`
	 * (`CheckScan.dropOperandEdit` deletes one operand of a homogeneous chain, and `duplicate-ternary-branches`
	 * ships that same shape under the same side-effect-free gate). It is deliberately not written, because
	 * what it would produce is a program that no longer reports the bug — which is the one outcome a
	 * finding of this kind must not have. Backlog T828 holds the counter-argument.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	public function noAutofixReason(): String {
		return 'the finding is a suspected TYPO, and every rewrite of one would SILENCE it rather than repair it: `a && a`'
			+ ' collapses to `a` and `a == a` to `true`, both of which compile and neither of which is the second operand the'
			+ ' author meant — and that operand is not in the source';
	}

	/** Walk `node`, flagging every comparison whose two operands are identical and call-free. */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, comparisonKinds: Array<String>, callKind: Null<String>
	): Void {
		final span: Null<Span> = node.span;
		if (
			span != null && node.children.length == 2 && comparisonKinds.contains(node.kind)
			&& MemberKinds.sameSource(node.children[0], node.children[1], source)
			&& !(callKind != null && MemberKinds.subtreeContainsKind(node.children[0], callKind))
		) out.push({
			file: file,
			span: span,
			rule: 'identical-operands',
			severity: Severity.Warning,
			message: 'both operands of this operator are identical'
		});
		for (c in node.children) walk(out, file, source, c, comparisonKinds, callKind);
	}

}

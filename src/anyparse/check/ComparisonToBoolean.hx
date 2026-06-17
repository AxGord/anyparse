package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags a comparison against a boolean literal — `x == true`, `x != false` and the like —
 * where the literal adds nothing (SonarLint S1125). Purely structural; `Severity.Info`,
 * report-only (`fix` yields no edits).
 *
 * ## Null-safety caveat
 *
 * Under strict null-safety `a?.b() == true` on a `Null<Bool>` is REQUIRED — `if (x)` on a
 * nullable Bool does not compile — so that `== true` is load-bearing, not redundant. With
 * no type information the check cannot prove non-nullability, so it conservatively SKIPS
 * any operand whose subtree reaches a null-safe access (`RefShape.nullSafeAccessKind`,
 * `a?.b`). The remaining hits are reported (never auto-fixed) for a human to judge.
 *
 * ## Grammar-agnostic
 *
 * Equality kinds come from `RefShape.equalityKinds`, the literal from `RefShape.boolLitKind`,
 * the null-safe skip from `RefShape.nullSafeAccessKind`. Unset equality kinds or literal kind
 * makes the check a no-op; unset null-safe kind only disables the skip.
 */
@:nullSafety(Strict)
final class ComparisonToBoolean implements Check {

	public function new() {}

	public function id(): String {
		return 'comparison-to-boolean';
	}

	public function description(): String {
		return 'a comparison against a boolean literal (x == true / x != false)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final equalityKinds: Array<String> = shape.equalityKinds ?? [];
		final boolLitKind: Null<String> = shape.boolLitKind;
		if (equalityKinds.length == 0 || boolLitKind == null) return [];
		final nullSafeKind: Null<String> = shape.nullSafeAccessKind;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, tree, equalityKinds, boolLitKind, nullSafeKind);
		}
		return violations;
	}

	/** Comparison-to-boolean has no autofix — removing `== true` may change semantics on a nullable. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/**
	 * Walk `node`, flagging an equality whose exactly one operand is a boolean literal and
	 * whose other operand does not reach a null-safe access.
	 */
	private static function walk(
		out: Array<Violation>, file: String, node: QueryNode, equalityKinds: Array<String>, boolLitKind: String,
		nullSafeKind: Null<String>
	): Void {
		final span: Null<Span> = node.span;
		if (span != null && node.children.length == 2 && equalityKinds.contains(node.kind)) {
			final leftIsBool: Bool = node.children[0].kind == boolLitKind;
			final rightIsBool: Bool = node.children[1].kind == boolLitKind;
			if (leftIsBool != rightIsBool) {
				final other: QueryNode = leftIsBool ? node.children[1] : node.children[0];
				if (!(nullSafeKind != null && RefactorSupport.subtreeContainsKind(other, nullSafeKind))) out.push({
					file: file,
					span: span,
					rule: 'comparison-to-boolean',
					severity: Severity.Info,
					message: 'comparison against a boolean literal'
				});
			}
		}
		for (c in node.children) walk(out, file, c, equalityKinds, boolLitKind, nullSafeKind);
	}

}

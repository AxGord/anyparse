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
 * Under strict null-safety `expr == true` on a `Null<Bool>` is REQUIRED — `if (x)` on a
 * nullable Bool does not compile — so that `== true` is load-bearing, not redundant. With
 * no type information the check cannot prove non-nullability, so it conservatively SKIPS any
 * operand whose subtree reaches a kind whose nullness it cannot rule out
 * (`RefShape.nullableOperandKinds` — Haxe `Call` / `FieldAccess` / `SafeFieldAccess`: a
 * method or `Map.get` result, a possibly-`@:optional` field, a `?.` access). It also does
 * not descend into macro-reification subtrees (`RefShape.opaqueKinds`), whose comparisons
 * are generated code rather than authored style. What remains — a bare identifier or a
 * boolean-operator expression operand — is reported (never auto-fixed) for a human to judge.
 *
 * ## Grammar-agnostic
 *
 * Equality kinds come from `RefShape.equalityKinds`, the literal from `RefShape.boolLitKind`,
 * the nullable-operand skip from `RefShape.nullableOperandKinds` (falling back to the single
 * `RefShape.nullSafeAccessKind` when unset), the macro skip from `RefShape.opaqueKinds`.
 * Unset equality kinds or literal kind makes the check a no-op.
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
		final nullableKinds: Array<String> = shape.nullableOperandKinds ?? (nullSafeKind != null ? [nullSafeKind] : []);
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, tree, equalityKinds, boolLitKind, nullableKinds, opaqueKinds);
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
	 * whose other operand is provably non-null Bool (does not reach `nullableKinds`). Macro
	 * reification subtrees (`opaqueKinds`) are not descended into.
	 */
	private static function walk(
		out: Array<Violation>, file: String, node: QueryNode, equalityKinds: Array<String>, boolLitKind: String,
		nullableKinds: Array<String>, opaqueKinds: Array<String>
	): Void {
		if (opaqueKinds.contains(node.kind)) return;
		final span: Null<Span> = node.span;
		if (span != null && node.children.length == 2 && equalityKinds.contains(node.kind)) {
			final leftIsBool: Bool = node.children[0].kind == boolLitKind;
			final rightIsBool: Bool = node.children[1].kind == boolLitKind;
			if (leftIsBool != rightIsBool) {
				final other: QueryNode = leftIsBool ? node.children[1] : node.children[0];
				if (!operandIsNullable(other, nullableKinds)) out.push({
					file: file,
					span: span,
					rule: 'comparison-to-boolean',
					severity: Severity.Info,
					message: 'comparison against a boolean literal'
				});
			}
		}
		for (c in node.children) walk(out, file, c, equalityKinds, boolLitKind, nullableKinds, opaqueKinds);
	}

	/** Whether `operand`'s subtree reaches any kind whose nullness the check cannot rule out. */
	private static function operandIsNullable(operand: QueryNode, nullableKinds: Array<String>): Bool {
		for (k in nullableKinds) if (RefactorSupport.subtreeContainsKind(operand, k)) return true;
		return false;
	}

}

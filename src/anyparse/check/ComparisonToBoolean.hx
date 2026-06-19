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
 * where the literal adds nothing (SonarLint S1125). Purely structural; `Severity.Info`.
 * `fix` rewrites the comparison to its operand — `x == true` / `x != false` → `x`,
 * `x == false` / `x != true` → `!x` — but ONLY when the operand is a boolean-operator
 * result (provably non-null Bool); see the null-safety caveat below.
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
 * boolean-operator expression operand — is reported for a human to judge.
 *
 * The same uncertainty bounds the autofix, but tighter: a bare identifier may resolve to a
 * `Null<Bool>` local (`final elseBool:Null<Bool>`) whose `== true` is load-bearing and
 * whose source the kind-based skip cannot classify, so `fix` rewrites ONLY a boolean-operator
 * operand (`RefShape.comparisonKinds` ∪ `RefShape.notKind`, parentheses unwrapped) — an
 * `&&` / `||` / `!` / comparison result is non-null `Bool` by construction. A bare-identifier
 * operand is reported but never auto-stripped.
 *
 * ## Grammar-agnostic
 *
 * Equality kinds come from `RefShape.equalityKinds`, the literal from `RefShape.boolLitKind`,
 * the nullable-operand skip from `RefShape.nullableOperandKinds` (falling back to the single
 * `RefShape.nullSafeAccessKind` when unset), the macro skip from `RefShape.opaqueKinds`, and
 * the autofix's provably-Bool gate from `RefShape.comparisonKinds` + `RefShape.notKind`.
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

	/**
	 * Rewrite each flagged comparison to its operand. `x == true` / `x != false` collapse
	 * to the operand verbatim; `x == false` / `x != true` collapse to its negation
	 * (`!operand`, parenthesized unless the operand is a bare identifier or already
	 * parenthesized, so the unary `!` binds correctly). Emitted ONLY for a boolean-operator
	 * operand (`provablyBool`) — a non-null `Bool` by construction; a bare identifier may be
	 * a `Null<Bool>` local whose `== true` is load-bearing, so it is left to the report.
	 * `eqKind` tells `==` from `!=`; unset (or no `boolLitKind`) → no-op.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final equalityKinds: Array<String> = shape.equalityKinds ?? [];
		final boolLitKind: Null<String> = shape.boolLitKind;
		final eqKind: Null<String> = shape.eqKind;
		if (equalityKinds.length == 0 || boolLitKind == null || eqKind == null) return [];
		final identKind: String = shape.identKind;
		final parenKind: Null<String> = shape.parenKind;
		final notKind: Null<String> = shape.notKind;
		final boolOpKinds: Array<String> = (shape.comparisonKinds ?? []).concat(notKind != null ? [notKind] : []);
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree == null) return [];

		final nodeByKey: Map<String, QueryNode> = [];
		indexEqualities(tree, equalityKinds, nodeByKey);

		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final node: Null<QueryNode> = nodeByKey['${span.from}:${span.to}'];
			if (node == null || node.children.length != 2) continue;
			final leftIsBool: Bool = node.children[0].kind == boolLitKind;
			final rightIsBool: Bool = node.children[1].kind == boolLitKind;
			if (leftIsBool == rightIsBool) continue;
			final lit: QueryNode = leftIsBool ? node.children[0] : node.children[1];
			final other: QueryNode = leftIsBool ? node.children[1] : node.children[0];
			if (!provablyBool(other, boolOpKinds, parenKind)) continue;
			final litSpan: Null<Span> = lit.span;
			final otherSpan: Null<Span> = other.span;
			if (litSpan == null || otherSpan == null) continue;
			final litIsTrue: Bool = StringTools.trim(source.substring(litSpan.from, litSpan.to)) == 'true';
			final isEq: Bool = node.kind == eqKind;
			final otherSrc: String = StringTools.trim(source.substring(otherSpan.from, otherSpan.to));
			edits.push({ span: span, text: isEq == litIsTrue ? otherSrc : negate(other, otherSrc, identKind, parenKind) });
		}
		return edits;
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

	/**
	 * Whether `operand` is a provably non-null Bool: a boolean-operator result
	 * (`&&` / `||` / `!` / a comparison), parentheses unwrapped. Such an operand can never be
	 * `Null<Bool>`, so stripping its `== true` is sound under strict null-safety. A bare
	 * identifier, field access or call is NOT provable without types and is left to the report.
	 */
	private static function provablyBool(operand: QueryNode, boolOpKinds: Array<String>, parenKind: Null<String>): Bool {
		var n: QueryNode = operand;
		while (parenKind != null && n.kind == parenKind && n.children.length == 1) n = n.children[0];
		return boolOpKinds.contains(n.kind);
	}

	/** `!operand`, parenthesizing a non-atomic operand so the unary `!` binds correctly. */
	private static function negate(operand: QueryNode, src: String, identKind: String, parenKind: Null<String>): String {
		return operand.kind == identKind || operand.kind == parenKind ? '!' + src : '!(' + src + ')';
	}

	/** Index every equality node by its `from:to` span key, for span-keyed violation lookup. */
	private static function indexEqualities(node: QueryNode, equalityKinds: Array<String>, out: Map<String, QueryNode>): Void {
		if (equalityKinds.contains(node.kind)) {
			final span: Null<Span> = node.span;
			if (span != null) out['${span.from}:${span.to}'] = node;
		}
		for (c in node.children) indexEqualities(c, equalityKinds, out);
	}

}

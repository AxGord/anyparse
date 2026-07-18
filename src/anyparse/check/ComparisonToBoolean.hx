package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import anyparse.query.TypeResolver;
import anyparse.query.TypeInfoProvider;

/**
 * Flags a comparison against a boolean literal — `x == true`, `x != false` and the like —
 * where the literal adds nothing (SonarLint S1125). Purely structural plus a declared-type
 * gate; `Severity.Info`. `fix` rewrites the comparison to its operand — `x == true` /
 * `x != false` → `x`, `x == false` / `x != true` → `!x` — but ONLY when the operand is a
 * boolean-operator result (provably non-null Bool); see the null-safety caveat below.
 *
 * ## Null-safety caveat
 *
 * Under strict null-safety `expr == true` on a `Null<Bool>` is REQUIRED — `if (x)` on a
 * nullable Bool does not compile — so that `== true` is load-bearing, not redundant. The
 * check conservatively SKIPS any operand whose subtree reaches a kind whose nullness it
 * cannot rule out (`RefShape.nullableOperandKinds` — Haxe `Call` / `FieldAccess` /
 * `SafeFieldAccess`: a method or `Map.get` result, a possibly-`@:optional` field, a `?.`
 * access). A BARE-IDENTIFIER operand is resolved through the grammar's `TypeInfoProvider`:
 * it is reported only when its declared type proves non-null Bool
 * (`TypeResolver.isProvablyNonNull`) — a `Null<Bool>` local (`final elseBool:Null<Bool>`)
 * or an unannotated / unresolvable identifier stays silent (unverifiable). Grammars with
 * no `TypeInfoProvider` fall back to reporting bare identifiers for a human to judge. It
 * also does not descend into macro-reification subtrees (`RefShape.opaqueKinds`), whose
 * comparisons are generated code rather than authored style.
 *
 * The same uncertainty bounds the autofix, but tighter: `fix` rewrites ONLY a
 * boolean-operator operand (`RefShape.comparisonKinds` ∪ `RefShape.notKind`, parentheses
 * unwrapped) — an `&&` / `||` / `!` / comparison result is non-null `Bool` by
 * construction. A bare-identifier operand is reported but never auto-stripped.
 *
 * ## Grammar-agnostic
 *
 * Equality kinds come from `RefShape.equalityKinds`, the literal from `RefShape.boolLitKind`,
 * the nullable-operand skip from `RefShape.nullableOperandKinds` (falling back to the single
 * `RefShape.nullSafeAccessKind` when unset), the macro skip from `RefShape.opaqueKinds`, the
 * identifier gate from `TypeInfoProvider.declaredTypes` + the nullability seams
 * (`nonNullableTypeNames` / `nullableWrapperTypeNames`), and the autofix's provably-Bool
 * gate from `RefShape.comparisonKinds` + `RefShape.notKind`. Unset equality kinds or
 * literal kind makes the check a no-op.
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
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final declaredTypes: Null<Map<Int, String>> = provider != null ? provider.declaredTypes(entry.source) : null;
			walk(
				violations, entry.file, tree, tree, seams.shape, declaredTypes, seams.equalityKinds, seams.boolLitKind,
				seams.nullableKinds, seams.opaqueKinds, seams.boolOpKinds
			);
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
	 * `eqKind` tells `==` from `!=` — it is required HERE only (unset → report-only), not
	 * in `run`'s gate.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final eqKind: Null<String> = seams.eqKind;
		return eqKind == null
			? []
			: CheckScan.applyBySpan(
				plugin, source, violations, seams.equalityKinds,
				(node, span) ->
					comparisonEdit(node, span, source, seams.boolLitKind, eqKind, seams.boolOpKinds, seams.identKind, seams.parenKind)
			);
	}

	/**
	 * Walk `node`, flagging an equality whose exactly one operand is a boolean literal and
	 * whose other operand is provably non-null Bool. A non-identifier operand must not reach
	 * `nullableKinds`; a BARE-IDENTIFIER operand is reported only when the grammar provides
	 * type info AND its declared type proves non-null (`TypeResolver.isProvablyNonNull`) — a
	 * `Null<Bool>` local's `== true` is load-bearing under strict null-safety, and an
	 * unresolvable / unannotated identifier cannot be verified, so both stay silent. Without
	 * a `TypeInfoProvider` the identifier falls back to being reported for a human to judge.
	 * Macro reification subtrees (`opaqueKinds`) are not descended into.
	 */
	private static function walk(
		out: Array<Violation>, file: String, node: QueryNode, root: QueryNode, shape: RefShape, declaredTypes: Null<Map<Int, String>>,
		equalityKinds: Array<String>, boolLitKind: String, nullableKinds: Array<String>, opaqueKinds: Array<String>,
		boolOpKinds: Array<String>
	): Void {
		if (opaqueKinds.contains(node.kind)) return;
		final span: Null<Span> = node.span;
		if (span != null && node.children.length == 2 && equalityKinds.contains(node.kind)) {
			final leftIsBool: Bool = node.children[0].kind == boolLitKind;
			final rightIsBool: Bool = node.children[1].kind == boolLitKind;
			if (leftIsBool != rightIsBool) {
				final other: QueryNode = leftIsBool ? node.children[1] : node.children[0];
				if (
					operandProvablyBool(other, root, shape, declaredTypes, boolOpKinds) && !operandIsNullable(other, nullableKinds)
				) out.push({
					file: file,
					span: span,
					rule: 'comparison-to-boolean',
					severity: Severity.Info,
					message: 'comparison against a boolean literal'
				});
			}
		}
		for (c in node.children)
			walk(out, file, c, root, shape, declaredTypes, equalityKinds, boolLitKind, nullableKinds, opaqueKinds, boolOpKinds);
	}

	/**
	 * Whether `other` is a PROVABLY non-null Bool operand — the same gate `fix` applies, so `run`
	 * flags nothing `fix` would refuse to strip on nullability grounds (closing the array-element /
	 * `ps[i] == true`-style false positive). Two proofs: a boolean-operator result (comparison /
	 * `&&` / `||` / `!`, parentheses unwrapped — `RefactorSupport.provablyBoolOperand`, non-null
	 * Bool by construction), or a bare identifier whose declared type proves non-null Bool
	 * (`TypeResolver.isProvablyNonNull`; a grammar with no `TypeInfoProvider` reports the bare
	 * identifier for a human to judge). Any other operand — an array element, a `Map.get` / method
	 * result, a possibly-`@:optional` field, a `?.` access, a `Null<Bool>` / unannotated identifier
	 * — is NOT provably non-null Bool, so its `== true` may be load-bearing under strict
	 * null-safety and is left unflagged.
	 */
	private static function operandProvablyBool(
		other: QueryNode, root: QueryNode, shape: RefShape, declaredTypes: Null<Map<Int, String>>, boolOpKinds: Array<String>
	): Bool {
		return RefactorSupport.provablyBoolOperand(other, boolOpKinds, shape.parenKind) || (
			other.kind == shape.identKind && (declaredTypes == null || TypeResolver.isProvablyNonNull(other, root, shape, declaredTypes))
		);
	}

	/** Whether `operand`'s subtree reaches any kind whose nullness the check cannot rule out. */
	private static function operandIsNullable(operand: QueryNode, nullableKinds: Array<String>): Bool {
		for (k in nullableKinds) if (RefactorSupport.subtreeContainsKind(operand, k)) return true;
		return false;
	}

	/** `!operand`, parenthesizing a non-atomic operand so the unary `!` binds correctly. */
	private static function negate(operand: QueryNode, src: String, identKind: String, parenKind: Null<String>): String {
		return operand.kind == identKind || operand.kind == parenKind ? '!' + src : '!(' + src + ')';
	}


	/**
	 * The replacement edit for one flagged comparison, or null when it cannot be
	 * rewritten: not a two-operand comparison, not exactly one boolean-literal
	 * operand, or the other operand not provably boolean. When rewritable, an
	 * `x == true` / `x != false` collapses to `x`, and an `x == false` / `x != true`
	 * to its negation (`negate` parenthesises unless the operand is an ident / paren).
	 */
	private static function comparisonEdit(
		node: QueryNode, span: Span, source: String, boolLitKind: String, eqKind: String, boolOpKinds: Array<String>, identKind: String,
		parenKind: Null<String>
	): Null<{ span: Span, text: String }> {
		if (node.children.length != 2) return null;
		final leftIsBool: Bool = node.children[0].kind == boolLitKind;
		final rightIsBool: Bool = node.children[1].kind == boolLitKind;
		if (leftIsBool == rightIsBool) return null;
		final lit: QueryNode = leftIsBool ? node.children[0] : node.children[1];
		final other: QueryNode = leftIsBool ? node.children[1] : node.children[0];
		if (!RefactorSupport.provablyBoolOperand(other, boolOpKinds, parenKind)) return null;
		final litSpan: Null<Span> = lit.span;
		final otherSpan: Null<Span> = other.span;
		if (litSpan == null || otherSpan == null) return null;
		final litIsTrue: Bool = StringTools.trim(source.substring(litSpan.from, litSpan.to)) == 'true';
		final isEq: Bool = node.kind == eqKind;
		final otherSrc: String = StringTools.trim(source.substring(otherSpan.from, otherSpan.to));
		return { span: span, text: isEq == litIsTrue ? otherSrc : negate(other, otherSrc, identKind, parenKind) };
	}


	/** Resolve the equality / bool-literal / paren seam kinds, or null when any required kind is unset. */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final equalityKinds: Array<String> = shape.equalityKinds ?? [];
		if (equalityKinds.length == 0) return null;
		final boolLitKind: Null<String> = shape.boolLitKind;
		if (boolLitKind == null) return null;
		final nullSafeKind: Null<String> = shape.nullSafeAccessKind;
		final nullableKinds: Array<String> = shape.nullableOperandKinds ?? (nullSafeKind != null ? [nullSafeKind] : []);
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final notKind: Null<String> = shape.notKind;
		final boolOpKinds: Array<String> = (shape.comparisonKinds ?? []).concat(notKind != null ? [notKind] : []);
		return {
			shape: shape,
			equalityKinds: equalityKinds,
			boolLitKind: boolLitKind,
			eqKind: shape.eqKind,
			nullableKinds: nullableKinds,
			opaqueKinds: opaqueKinds,
			identKind: shape.identKind,
			parenKind: shape.parenKind,
			boolOpKinds: boolOpKinds
		};
	}

}

/** The resolved seams `ComparisonToBoolean` reads in both `run` and `fix`. */
private typedef Seams = {
	final shape: RefShape;
	final equalityKinds: Array<String>;
	final boolLitKind: String;
	final eqKind: Null<String>;
	final nullableKinds: Array<String>;
	final opaqueKinds: Array<String>;
	final identKind: String;
	final parenKind: Null<String>;
	final boolOpKinds: Array<String>;
};

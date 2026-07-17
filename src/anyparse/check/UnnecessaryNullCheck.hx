package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

/**
 * Flags a comparison against `null` whose other operand is provably non-null, so
 * the comparison is a constant — `if (x != null)` where `x` cannot be null.
 *
 * ## Type-aware, conservative
 *
 * The operand is proven non-null only when it is a plain identifier whose declared
 * type is recovered via `TypeInfoProvider.declaredTypes` AND is either a value type
 * the language can never null (`RefShape.nonNullableTypeNames` — Haxe `Int` / `Float`
 * / `Bool` / `UInt`), or any non-`Null<…>` nominal type while the enclosing type is
 * null-checked (`RefShape.nullSafetyMetaName`, e.g. `@:nullSafety`). Everything else —
 * an unannotated local, a `Null<…>` field (absent from `declaredTypes`), a method-call
 * or field-access operand — keeps the conservative default and is NOT flagged, so the
 * check never reports a load-bearing null guard. Macro-reification subtrees
 * (`RefShape.opaqueKinds`) are not descended into.
 *
 * `Severity.Info`; `fix` conservatively drops the redundant comparison where a safe span
 * rewrite exists — unwrap the always-true `if (x != null)`, delete the always-false
 * `if (x == null)`, or drop a conjunct / disjunct from a homogeneous `&&` / `||` chain (shared
 * with `dead-null-guard` via `CheckScan.simplifyNullComparisonFixes`) — and refuses elsewhere.
 * A default-null parameter (`p:T = null`) is exempted at the proof, so it is never flagged;
 * the residual soundness caveat is the proof trusts `@:nullSafety` without a strict-null check.
 */
@:nullSafety(Strict)
final class UnnecessaryNullCheck implements Check {

	public function new() {}

	public function id(): String {
		return 'unnecessary-null-check';
	}

	public function description(): String {
		return 'a comparison against null whose operand is provably non-null';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final equalityKinds: Array<String> = shape.equalityKinds ?? [];
		final nullLitKind: Null<String> = shape.nullLiteralKind;
		if (equalityKinds.length == 0 || nullLitKind == null) return [];
		final nullLit: String = nullLitKind;
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final root: QueryNode = tree;
			final declaredTypes: Map<Int, String> = provider != null ? provider.declaredTypes(entry.source) : [];
			function walk(node: QueryNode): Void {
				if (opaqueKinds.contains(node.kind)) return;
				final span: Null<Span> = node.span;
				if (span != null && node.children.length == 2 && equalityKinds.contains(node.kind)) {
					final leftIsNull: Bool = node.children[0].kind == nullLit;
					final rightIsNull: Bool = node.children[1].kind == nullLit;
					if (leftIsNull != rightIsNull) {
						final operand: QueryNode = leftIsNull ? node.children[1] : node.children[0];
						if (TypeResolver.isProvablyNonNull(operand, root, shape, declaredTypes)) violations.push({
							file: entry.file,
							span: span,
							rule: 'unnecessary-null-check',
							severity: Severity.Info,
							message: 'null check is redundant — operand is never null'
						});
					}
				}
				for (c in node.children) walk(c);
			}
			walk(tree);
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return CheckScan.simplifyNullComparisonFixes(plugin, source, violations);
	}

}

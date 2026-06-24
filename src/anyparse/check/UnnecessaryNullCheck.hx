package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

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
 * `Severity.Info`; report-only — the correct rewrite (drop the guard and keep the
 * body, or collapse an `&&` operand) is context-dependent, so `fix` is a no-op.
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
		final nonNullableTypeNames: Array<String> = shape.nonNullableTypeNames ?? [];
		final nullSafetyMetaName: Null<String> = shape.nullSafetyMetaName;
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
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
						if (isProvablyNonNull(operand, root, shape, nonNullableTypeNames, nullSafetyMetaName, declaredTypes)) violations.push({
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
		return [];
	}

	/**
	 * Whether `operand` is a plain identifier resolvable to a provably non-null type —
	 * a `nonNullableTypeNames` value type, or any recovered nominal type while the
	 * enclosing declaration is null-checked (`nullSafetyMetaName`).
	 */
	private static function isProvablyNonNull(
		operand: QueryNode, root: QueryNode, shape: RefShape, nonNullableTypeNames: Array<String>, nullSafetyMetaName: Null<String>,
		declaredTypes: Map<Int, String>
	): Bool {
		final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(operand, root, shape);
		if (bindingFrom == null) return false;
		final optionalParamKind: Null<String> = shape.optionalParamKind;
		if (optionalParamKind != null && TypeResolver.bindingIsOptionalParam(root, bindingFrom, optionalParamKind)) return false;
		final typeName: Null<String> = declaredTypes[bindingFrom];
		if (typeName == null) return false;
		if (nonNullableTypeNames.contains(typeName)) return true;
		final nullableWrapperTypeNames: Array<String> = shape.nullableWrapperTypeNames ?? [];
		if (nullableWrapperTypeNames.contains(typeName)) return false;
		final opSpan: Null<Span> = operand.span;
		return nullSafetyMetaName != null && opSpan != null
			&& TypeResolver.enclosingIsNullSafe(root, opSpan, nullSafetyMetaName, shape.nullSafetyDisableArg);
	}

}

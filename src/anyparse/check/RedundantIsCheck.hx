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
 * Flags an `is` type-check `x is T` that is provably ALWAYS TRUE — `x` is a plain
 * identifier whose declared type already equals the checked type `T` AND is provably
 * non-null, so the runtime test can never fail. `Severity.Info`.
 *
 * ## Type-aware, conservative — always-true only
 *
 * Only the always-TRUE direction is detected, and only soundly: the value operand
 * must be a plain identifier proven non-null (`TypeResolver.isProvablyNonNull` —
 * required because `null is T` is FALSE, so a nullable operand's check is not a
 * constant) whose declared type SOURCE (`TypeInfoProvider.declaredTypeSources`) equals
 * the checked type's written source, compared via `TypeResolver.sameTypeSource`
 * (whitespace- and import-aware). A subtype relation (`x:Sub is Base`) is NOT proven —
 * anyparse models no class hierarchy — so only the exact same type is flagged; a
 * subtype/interface check is a safe miss.
 *
 * The always-FALSE direction (`x is String` where `x:Int`) is intentionally NOT
 * attempted: telling an unrelated type from a supertype / interface needs the class
 * hierarchy anyparse does not have, so it could not be done without false positives.
 * Macro-reification subtrees (`RefShape.opaqueKinds`) are not descended into.
 *
 * `fix` unwraps the always-true `is`-check where a safe span rewrite exists — a sole-condition
 * `if (x is T)` or a `&&`-conjunct (via `CheckScan.simplifyConditionFixes`) — refusing elsewhere.
 * A default-null `s:T = null` is exempted (`null is T` is false), so `s is T` is never flagged.
 */
@:nullSafety(Strict)
final class RedundantIsCheck implements Check {

	public function new() {}

	public function id(): String {
		return 'redundant-is-check';
	}

	public function description(): String {
		return 'an is-check whose operand already has the checked type';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final isExprKind: Null<String> = shape.isExprKind;
		if (isExprKind == null) return [];
		final kind: String = isExprKind;
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		if (provider == null) return [];
		final typed: TypeInfoProvider = provider;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final root: QueryNode = tree;
			final declaredTypes: Map<Int, String> = typed.declaredTypes(entry.source);
			final declaredTypeSources: Map<Int, String> = typed.declaredTypeSources(entry.source);
			final importMap: Map<String, String> = typed.importMap(entry.source);
			function walk(node: QueryNode): Void {
				if (opaqueKinds.contains(node.kind)) return;
				if (node.kind == kind && node.children.length == 2) {
					final span: Null<Span> = node.span;
					final operand: QueryNode = node.children[0];
					final typeSpan: Null<Span> = node.children[1].span;
					if (span != null && typeSpan != null && TypeResolver.isProvablyNonNull(operand, root, shape, declaredTypes)) {
						final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(operand, root, shape);
						final operandSource: Null<String> = bindingFrom == null ? null : declaredTypeSources[bindingFrom];
						final typeSource: String = entry.source.substring(typeSpan.from, typeSpan.to);
						if (operandSource != null && TypeResolver.sameTypeSource(operandSource, typeSource, importMap)) violations.push({
							file: entry.file,
							span: span,
							rule: 'redundant-is-check',
							severity: Severity.Info,
							message: 'is-check is always true — operand is already $operandSource'
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
		final isExprKind: Null<String> = plugin.refShape().isExprKind;
		return isExprKind == null ? [] : CheckScan.simplifyConditionFixes(plugin, source, violations, [isExprKind], _ -> true);
	}

}

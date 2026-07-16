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
 * Flags a null-coalescing whose left operand is provably non-null —
 * `nonNull ?? fallback` — so the right operand is dead. `Severity.Info`; `fix`
 * unwraps it to the left operand.
 *
 * ## Type-aware, conservative
 *
 * The left operand must be a plain identifier proven non-null by
 * `TypeResolver.isProvablyNonNull` — a `RefShape.nonNullableTypeNames` value type,
 * or a non-`Null<…>` nominal local / parameter / field while the enclosing type is
 * null-checked (`RefShape.nullSafetyMetaName`). A non-identifier left operand (a
 * call / field access whose type is unknown), an operand with no recovered type, an
 * optional parameter, or a `Null<…>` / `Dynamic` operand keeps the conservative
 * default and is not flagged, so a load-bearing fallback is never removed.
 * Macro-reification subtrees (`RefShape.opaqueKinds`) are not descended into.
 */
@:nullSafety(Strict)
final class RedundantNullCoalescing implements Check {

	public function new() {}

	public function id(): String {
		return 'redundant-null-coalescing';
	}

	public function description(): String {
		return 'a null-coalescing whose left operand is never null';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		if (provider == null) return [];
		final typed: TypeInfoProvider = provider;
		final coalKind: String = seams.coalKind;
		final opaqueKinds: Array<String> = seams.opaqueKinds;
		final shape: RefShape = seams.shape;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final root: QueryNode = tree;
			final declaredTypes: Map<Int, String> = typed.declaredTypes(entry.source);
			function walk(node: QueryNode): Void {
				if (opaqueKinds.contains(node.kind)) return;
				if (node.kind == coalKind && node.children.length == 2) {
					final span: Null<Span> = node.span;
					if (span != null && TypeResolver.isProvablyNonNull(node.children[0], root, shape, declaredTypes)) violations.push({
						file: entry.file,
						span: span,
						rule: 'redundant-null-coalescing',
						severity: Severity.Info,
						message: 'right operand is dead — left operand is never null'
					});
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
		final seams: Null<Seams> = resolveSeams(plugin);
		return seams == null
			? []
			: CheckScan.applyBySpan(plugin, source, violations, [seams.coalKind], (node, span) -> {
				if (node.children.length != 2) return null;
				final leftSpan: Null<Span> = node.children[0].span;
				return leftSpan == null ? null : { span: span, text: source.substring(leftSpan.from, leftSpan.to) };
			});
	}


	/** Resolve the null-coalescing seam kind plus opaque kinds and shape, or null when the coalesce kind is unset. */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final nullCoalesceKind: Null<String> = shape.nullCoalesceKind;
		return nullCoalesceKind == null ? null : { coalKind: nullCoalesceKind, opaqueKinds: shape.opaqueKinds ?? [], shape: shape };
	}

}

/**
 * The resolved seams `RedundantNullCoalescing` reads in `run` and `fix`; `opaqueKinds` / `shape` are read only by `run` (the type-aware walk).
 */
private typedef Seams = {
	final coalKind: String;
	final opaqueKinds: Array<String>;
	final shape: RefShape;
};

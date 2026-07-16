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
 * Flags a typed cast / type-check whose target type already equals its operand's
 * declared type — `cast(x, T)` / `(x : T)` where `x` is declared `T` — so the cast
 * is a no-op. `Severity.Info`; `fix` unwraps it to the operand.
 *
 * ## Type-aware, conservative
 *
 * The operand must be a plain identifier whose declared type is recovered via `TypeInfoProvider.declaredTypeSources`, and the cast's target type via `TypeInfoProvider.castTargetSources`; both are the VERBATIM written type SOURCE. A non-identifier
 * operand (a call / field access whose type is unknown), an operand with no
 * recovered type, or a target type that differs keeps the conservative default and
 * is not flagged. The untyped `cast x` form carries no target type and is excluded
 * by `RefShape.typedCastKinds`. Macro-reification subtrees (`RefShape.opaqueKinds`)
 * are not descended into.
 *
 * Comparison is on the written type SOURCE (whitespace-insensitive), which is sound within one file — a byte-identical spelling cannot denote two different types, so the unwrap autofix is safe. Differing spellings of the same type (`Eof` vs `haxe.io.Eof`) are conservatively treated as different (a safe miss); resolving those needs a typer anyparse does not have.
 */
@:nullSafety(Strict)
final class RedundantCast implements Check {

	public function new() {}

	public function id(): String {
		return 'redundant-cast';
	}

	public function description(): String {
		return 'a typed cast whose target type equals its operand type';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final shape: RefShape = seams.shape;
		final typedCastKinds: Array<String> = seams.typedCastKinds;
		final opaqueKinds: Array<String> = seams.opaqueKinds;
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		if (provider == null) return [];
		final typed: TypeInfoProvider = provider;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final root: QueryNode = tree;
			final declaredTypeSources: Map<Int, String> = typed.declaredTypeSources(entry.source);
			final castTargets: Map<Int, String> = typed.castTargetSources(entry.source);
			final importMap: Map<String, String> = typed.importMap(entry.source);
			function walk(node: QueryNode): Void {
				if (opaqueKinds.contains(node.kind)) return;
				if (typedCastKinds.contains(node.kind)) {
					final span: Null<Span> = node.span;
					if (span != null && node.children.length == 1) {
						final operandSource: Null<String> = operandType(node.children[0], root, shape, declaredTypeSources);
						final targetSource: Null<String> = TypeResolver.castTargetWithin(span, castTargets);
						if (
							operandSource != null && targetSource != null
							&& TypeResolver.sameTypeSource(operandSource, targetSource, importMap)
						) violations.push({
							file: entry.file,
							span: span,
							rule: 'redundant-cast',
							severity: Severity.Info,
							message: 'redundant cast — operand is already $targetSource'
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
		final seams: Null<Seams> = resolveSeams(plugin);
		return seams == null
			? []
			: CheckScan.applyBySpan(plugin, source, violations, seams.typedCastKinds, (node, span) -> {
				if (node.children.length != 1) return null;
				final operand: QueryNode = node.children[0];
				final opSpan: Null<Span> = operand.span;
				return opSpan == null ? null : { span: span, text: source.substring(opSpan.from, opSpan.to) };
			});
	}

	/** The verbatim source of the identifier `operand`'s declared `:Type` annotation, or null. */
	private static function operandType(
		operand: QueryNode, root: QueryNode, shape: RefShape, declaredTypeSources: Map<Int, String>
	): Null<String> {
		final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(operand, root, shape);
		return bindingFrom == null ? null : declaredTypeSources[bindingFrom];
	}


	/** Resolve the typed-cast + opaque seam kinds (with the shape for downstream type lookup), or null when no typed-cast kind exists. */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final typedCastKinds: Array<String> = shape.typedCastKinds ?? [];
		if (typedCastKinds.length == 0) return null;
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		return { shape: shape, typedCastKinds: typedCastKinds, opaqueKinds: opaqueKinds };
	}

}

/** The resolved seams `RedundantCast` reads in both `run` and `fix`. */
private typedef Seams = {
	final shape: RefShape;
	final typedCastKinds: Array<String>;
	final opaqueKinds: Array<String>;
};

package anyparse.check.common.types;

import anyparse.query.SymbolIndex;

/**
 * Flags a runtime-checked cast `cast(x, T)` that is a redundant UPCAST — `x`'s declared
 * type `S` is a (transitive) subtype of `T`, so the runtime type test always passes and
 * the cast is a no-op (an `S` is usable wherever a `T` is expected without casting).
 * `Severity.Info`; report-only.
 *
 * ## Completes the cast triad
 *
 * The three relations between an operand type `S` and a checked-cast target `T` partition
 * cleanly: equal (`redundant-cast`, with an unwrap autofix), `S <: T` (this check — an
 * always-succeeding upcast), and unrelated (`impossible-cast` — an always-failing cast).
 * The subtype relation is the cross-file hierarchy `SubtypeGraph.isSubtype` resolves
 * (extends + implements), so an interface target (`cast(impl, I)` where `impl`'s class
 * implements `I`) is flagged too. No non-null proof is needed — a redundant upcast is a
 * no-op for any value, `null` included.
 *
 * Conservative: flags only when the operand is a plain identifier whose declared type is a
 * proven strict subtype of the target. Only the runtime `cast(x, T)` form
 * (`RefShape.checkedCastKind`) is inspected — the compile-time `(x : T)` ascription is a
 * different node. A non-identifier operand, a generic / `Null<…>` / `Dynamic` type, an unindexed supertype link, a
 * target or a link another package's namesake shares, or a same / unrelated type is a safe miss (the same-type and
 * unrelated cases belong to `redundant-cast` / `impossible-cast`). Macro-reification
 * subtrees (`RefShape.opaqueKinds`) are not descended into.
 *
 * `fix` unwraps the cast to its operand (`cast(x, T)` -> `x`) — the flagged operand is always a plain
 * identifier, so no reparenthesisation is needed; the finding stays `Info` and the unwrap runs under `--fix`.
 */
@:nullSafety(Strict)
final class RedundantUpcast extends RuleBase {

	public function new() {
		super('redundant-upcast', 'a checked cast whose operand type is already a subtype of the target', RuleCategory.Types);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final checkedCastKind: Null<String> = shape.checkedCastKind;
		if (checkedCastKind == null) return [];
		final kind: String = checkedCastKind;
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		return RunScan.collectTyped(files, plugin, (entry, tree, typed, index, violations) -> {
			final root: QueryNode = tree;
			final declaredTypes: Map<Int, String> = typed.declaredTypes(entry.source);
			final castTargets: Map<Int, String> = typed.castTargetSources(entry.source);
			final declaredSources: Map<Int, String> = typed.declaredTypeSources(entry.source);
			function walk(node: QueryNode): Void {
				if (opaqueKinds.contains(node.kind)) return;
				if (node.kind == kind && node.children.length == 1) {
					final span: Null<Span> = node.span;
					if (span != null) {
						final binding: Null<Int> = TypeResolver.identBindingFrom(node.children[0], root, shape);
						final sName: Null<String> = binding == null ? null : TypeResolver.simpleNominalName(declaredTypes[binding]);
						final sSource: Null<String> = binding == null ? null : declaredSources[binding];
						final tSource: Null<String> = TypeResolver.castTargetWithin(span, castTargets);
						final tName: Null<String> = TypeResolver.simpleNominalName(tSource);
						// Both types resolve in this file: a namesake in the operand's chain proves nothing, and neither does an operand
						// type sharing a project subtype's name.
						if (
							sName != null && tName != null && sSource != null && tSource != null
							&& index.subtypes.isSubtype(sSource.trim(), tSource.trim(), entry.file, span.from, entry.file, binding)
						) violations.push({
							file: entry.file,
							span: span,
							rule: 'redundant-upcast',
							severity: Severity.Info,
							message: 'redundant upcast — $sName is already a $tName'
						});
					}
				}
				for (c in node.children) walk(c);
			}
			walk(tree);
		});
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final checkedCastKind: Null<String> = plugin.refShape().checkedCastKind;
		return checkedCastKind == null
			? []
			: CheckScan.applyBySpan(plugin, source, violations, [checkedCastKind], (node, span) -> {
				if (node.children.length != 1) return null;
				final opSpan: Null<Span> = node.children[0].span;
				return opSpan == null ? null : { span: span, text: source.substring(opSpan.from, opSpan.to) };
			});
	}

}

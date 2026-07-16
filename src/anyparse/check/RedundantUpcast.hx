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
 * The subtype relation is the cross-file hierarchy `SymbolIndex.isSubtype` resolves
 * (extends + implements), so an interface target (`cast(impl, I)` where `impl`'s class
 * implements `I`) is flagged too. No non-null proof is needed — a redundant upcast is a
 * no-op for any value, `null` included.
 *
 * Conservative: flags only when the operand is a plain identifier whose declared type is a
 * proven strict subtype of the target. Only the runtime `cast(x, T)` form
 * (`RefShape.checkedCastKind`) is inspected — the compile-time `(x : T)` ascription is a
 * different node. A non-identifier operand, a generic / `Null<…>` / `Dynamic` type, an
 * unindexed supertype link, or a same / unrelated type is a safe miss (the same-type and
 * unrelated cases belong to `redundant-cast` / `impossible-cast`). Macro-reification
 * subtrees (`RefShape.opaqueKinds`) are not descended into.
 *
 * Report-only: an explicit upcast is occasionally load-bearing (overload disambiguation),
 * so removing it is left to the author.
 */
@:nullSafety(Strict)
final class RedundantUpcast implements Check {

	public function new() {}

	public function id(): String {
		return 'redundant-upcast';
	}

	public function description(): String {
		return 'a checked cast whose operand type is already a subtype of the target';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final checkedCastKind: Null<String> = shape.checkedCastKind;
		if (checkedCastKind == null) return [];
		final kind: String = checkedCastKind;
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		if (provider == null) return [];
		final typed: TypeInfoProvider = provider;
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final root: QueryNode = tree;
			final declaredTypes: Map<Int, String> = typed.declaredTypes(entry.source);
			final castTargets: Map<Int, String> = typed.castTargetSources(entry.source);
			function walk(node: QueryNode): Void {
				if (opaqueKinds.contains(node.kind)) return;
				if (node.kind == kind && node.children.length == 1) {
					final span: Null<Span> = node.span;
					if (span != null) {
						final sName: Null<String> = TypeResolver.simpleNominalName(TypeResolver.identTypeName(
							node.children[0], root, shape, declaredTypes
						));
						final tName: Null<String> = TypeResolver.simpleNominalName(TypeResolver.castTargetWithin(span, castTargets));
						if (sName != null && tName != null && index.isSubtype(sName, tName)) violations.push({
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
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

}

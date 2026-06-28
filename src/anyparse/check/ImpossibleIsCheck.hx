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
 * Flags an `is` type-check `x is T` that is provably ALWAYS FALSE — `x` is a plain
 * identifier whose declared type `S` and the checked type `T` are two UNRELATED
 * classes, so no runtime value of static type `S` can ever be a `T`. `Severity.Warning`;
 * report-only.
 *
 * ## Sound under Haxe single inheritance
 *
 * A value of static type `S` is some `R <: S`; `x is T` is true iff `R <: T`. For a
 * class `R` to satisfy both (`S` and `T` being classes), `S` and `T` must both lie on
 * `R`'s single class-ancestor chain — so they are comparable. Two UNRELATED classes
 * therefore share no common subtype and the test can never pass. A `null` operand is
 * consistent (`null is T` is also false), so — unlike `redundant-is-check`
 * (always-true) — no non-null proof is needed.
 *
 * Conservative: flags only when BOTH `S` and `T` resolve to a unique indexed CLASS
 * decl (interface / abstract / enum / typedef on either side → open world or implicit
 * conversions → skip), are distinct, and neither is a transitive supertype of the other
 * with BOTH closures fully resolved inside the index — `SymbolIndex.unrelatedClasses`.
 * An unindexed supertype link (an external type, or a project file not in the lint set)
 * makes the relation unknown → skip. Generics / parametric / `Null<...>` / `Dynamic`
 * operands or checked types never resolve to an indexed class → skip. Every skip is a safe miss. Residual boundary: type names resolve by SIMPLE name, so an external supertype whose simple name collides with an unrelated indexed class could mis-resolve — it does not arise within one self-contained project tree. Macro-reification subtrees (`RefShape.opaqueKinds`) are not descended into.
 *
 * Report-only: the right rewrite (the branch is dead — drop it, or fix the declared
 * type) is context-dependent, exactly as for `redundant-is-check`.
 */
@:nullSafety(Strict)
final class ImpossibleIsCheck implements Check {

	public function new() {}

	public function id(): String {
		return 'impossible-is-check';
	}

	public function description(): String {
		return 'an is-check between two unrelated classes that is always false';
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
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree == null) continue;
			final root: QueryNode = tree;
			final declaredTypes: Map<Int, String> = typed.declaredTypes(entry.source);
			function walk(node: QueryNode): Void {
				if (opaqueKinds.contains(node.kind)) return;
				if (node.kind == kind && node.children.length == 2) {
					final span: Null<Span> = node.span;
					final operand: QueryNode = node.children[0];
					final typeSpan: Null<Span> = node.children[1].span;
					if (span != null && typeSpan != null) {
						final sName: Null<String> = TypeResolver.simpleNominalName(TypeResolver.identTypeName(
							operand, root, shape, declaredTypes
						));
						final tName: Null<String> = TypeResolver.simpleNominalName(entry.source.substring(typeSpan.from, typeSpan.to));
						if (sName != null && tName != null && index.unrelatedClasses(sName, tName)) violations.push({
							file: entry.file,
							span: span,
							rule: 'impossible-is-check',
							severity: Severity.Warning,
							message: 'is-check is always false — $sName and $tName are unrelated classes'
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

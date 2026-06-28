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
 * Flags a runtime-checked cast `cast(x, T)` that can NEVER succeed — `x`'s declared type
 * `S` and the target type `T` are two UNRELATED classes, so under Haxe single inheritance
 * no value of `S` is ever a `T`; the cast can never produce a usable `T` (it throws for any non-null value, yields `null` for a null one). `Severity.Warning`; report-only.
 *
 * ## The cast-sibling of `impossible-is-check`
 *
 * `cast(x, T)` compiles to a runtime `Std.isOfType(x, T)` test that throws on mismatch
 * (unlike the compile-time `(x : T)` ascription, which would simply not compile for
 * unrelated types — hence only the `RefShape.checkedCastKind` form is inspected). The
 * soundness is identical to `impossible-is-check`: a value of static `S` is some `R <: S`;
 * the test passes iff `R <: T`; two unrelated classes share no common subtype, so it can
 * never pass. No non-null proof is needed — the cast never yields a usable `T` regardless.
 *
 * Conservative: flags only when the operand is a plain identifier whose declared type and
 * the target type BOTH resolve to a unique indexed CLASS, are distinct, and are unrelated
 * with fully index-resolved supertype closures (`SymbolIndex.unrelatedClasses`). An
 * interface / abstract / enum / typedef on either side, a generic / `Null<…>` / `Dynamic`
 * type, an unindexed supertype link, or a non-identifier operand is a safe miss.
 * Macro-reification subtrees (`RefShape.opaqueKinds`) are not descended into.
 *
 * Report-only: the dead cast is a bug, but the right fix (correct the type, drop the cast,
 * restructure) is context-dependent.
 */
@:nullSafety(Strict)
final class ImpossibleCast implements Check {

	public function new() {}

	public function id(): String {
		return 'impossible-cast';
	}

	public function description(): String {
		return 'a checked cast between two unrelated classes that always throws';
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
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
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
						if (sName != null && tName != null && index.unrelatedClasses(sName, tName)) violations.push({
							file: entry.file,
							span: span,
							rule: 'impossible-cast',
							severity: Severity.Warning,
							message: 'cast can never yield a usable value — $sName and $tName are unrelated classes'
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

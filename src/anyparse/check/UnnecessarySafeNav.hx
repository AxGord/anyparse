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
 * Flags a null-safe field access (`a?.b`) whose receiver is provably non-null, so
 * the `?.` guard cannot ever short-circuit — a plain `.` access is equivalent.
 *
 * ## Type-aware, conservative
 *
 * The receiver is proven non-null only when it is a plain identifier whose declared
 * type is recovered via `TypeInfoProvider.declaredTypes` AND is either a value type
 * the language can never null (`RefShape.nonNullableTypeNames`), or any non-`Null<…>`
 * nominal type while the enclosing type is null-checked (`RefShape.nullSafetyMetaName`).
 * Everything else — an unannotated local, a `Null<…>` / `Dynamic` operand, an optional
 * parameter, or a non-identifier receiver (a chained `a.b?.c` / `a()?.c`) — keeps the
 * conservative default and is NOT flagged. The shared prover is
 * `TypeResolver.isProvablyNonNull`, also used by `unnecessary-null-check` and
 * `redundant-null-coalescing`. Macro-reification subtrees (`RefShape.opaqueKinds`) are
 * not descended into.
 *
 * Unlike `unnecessary-null-check`, the rewrite is unambiguous: dropping the `?` from a
 * provably non-null `?.` preserves semantics exactly, so `fix` rewrites `?.` to `.`.
 * `Severity.Info`.
 */
@:nullSafety(Strict)
final class UnnecessarySafeNav implements Check {

	public function new() {}

	public function id(): String {
		return 'unnecessary-safe-nav';
	}

	public function description(): String {
		return 'a null-safe access (?.) whose receiver is provably non-null';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final safeNavKind: Null<String> = shape.nullSafeAccessKind;
		if (safeNavKind == null) return [];
		final kind: String = safeNavKind;
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		if (provider == null) return [];
		final typed: TypeInfoProvider = provider;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree == null) continue;
			final root: QueryNode = tree;
			final declaredTypes: Map<Int, String> = typed.declaredTypes(entry.source);
			function walk(node: QueryNode): Void {
				if (opaqueKinds.contains(node.kind)) return;
				if (node.kind == kind && node.children.length == 1) {
					final span: Null<Span> = node.span;
					final receiver: QueryNode = node.children[0];
					if (span != null && TypeResolver.isProvablyNonNull(receiver, root, shape, declaredTypes)) violations.push({
						file: entry.file,
						span: span,
						rule: 'unnecessary-safe-nav',
						severity: Severity.Info,
						message: 'null-safe access is redundant — receiver is never null'
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
		final marker: String = '?.';
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final rel: Int = source.substring(span.from, span.to).indexOf(marker);
			if (rel < 0) continue;
			final at: Int = span.from + rel;
			edits.push({ span: new Span(at, at + marker.length), text: '.' });
		}
		return edits;
	}

}

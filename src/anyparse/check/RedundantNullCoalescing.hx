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
import anyparse.query.RefactorSupport;

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
		final shape: RefShape = plugin.refShape();
		final nullCoalesceKind: Null<String> = shape.nullCoalesceKind;
		if (nullCoalesceKind == null) return [];
		final coalKind: String = nullCoalesceKind;
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
		final shape: RefShape = plugin.refShape();
		final nullCoalesceKind: Null<String> = shape.nullCoalesceKind;
		if (nullCoalesceKind == null) return [];
		final coalKind: String = nullCoalesceKind;
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree == null) return [];
		final byKey: Map<String, QueryNode> = [];
		RefactorSupport.indexNodesByKind(tree, [coalKind], byKey);
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final node: Null<QueryNode> = byKey['${span.from}:${span.to}'];
			if (node == null || node.children.length != 2) continue;
			final left: QueryNode = node.children[0];
			final leftSpan: Null<Span> = left.span;
			if (leftSpan == null) continue;
			edits.push({ span: span, text: source.substring(leftSpan.from, leftSpan.to) });
		}
		return edits;
	}

}

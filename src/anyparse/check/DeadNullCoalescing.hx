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
 * Flags a null-coalescing (`a ?? b`) whose left operand is already non-null **by
 * flow** on every path reaching it — the right operand is dead. The flow-only
 * counterpart of `redundant-null-coalescing`.
 *
 * ## Flow-only — complements `redundant-null-coalescing`, never duplicates it
 *
 * Non-null-ness comes purely from `NullFlow`: an earlier `!= null` guard narrowing
 * this path (then-arm), an `== null` guard's else-arm, or a syntactically non-null
 * assignment. It skips any left operand the declared prover
 * `TypeResolver.isProvablyNonNull` already proves non-null — those belong to
 * `redundant-null-coalescing`. So a dead `??` fallback is reported exactly once.
 *
 * Conservative throughout (see `NullFlow`): every uncertainty collapses to
 * `Unknown`, so only a genuinely dead fallback is reported. `Severity.Info`;
 * `fix` unwraps to the left operand, the same rewrite `redundant-null-coalescing` applies (sound whenever the proven flow facts hold).
 */
@:nullSafety(Strict)
final class DeadNullCoalescing implements Check {

	public function new() {}

	public function id(): String {
		return 'dead-null-coalescing';
	}

	public function description(): String {
		return 'a null-coalescing whose left operand is already non-null on every path reaching it';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final nullCoalesceKind: Null<String> = shape.nullCoalesceKind;
		final identKind: Null<String> = shape.identKind;
		if (nullCoalesceKind == null || identKind == null) return [];
		final coalKind: String = nullCoalesceKind;
		final ident: String = identKind;
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		if (provider == null) return [];
		final typed: TypeInfoProvider = provider;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final root: QueryNode = tree;
			final declaredTypes: Map<Int, String> = typed.declaredTypes(entry.source);
			NullFlow.analyze(root, shape, entry.source, (node, facts) -> {
				if (node.kind != coalKind || node.children.length != 2) return;
				final left: QueryNode = node.children[0];
				final span: Null<Span> = node.span;
				if (left.kind != ident || span == null) return;
				final name: Null<String> = left.name;
				if (name == null) return;
				// Owned by `redundant-null-coalescing` when the declared type proves it.
				if (TypeResolver.isProvablyNonNull(left, root, shape, declaredTypes)) return;
				if (facts.nonNull(name)) violations.push({
					file: entry.file,
					span: span,
					rule: 'dead-null-coalescing',
					severity: Severity.Info,
					message: 'right operand is dead — left operand is already non-null on this path'
				});
			});
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
		return CheckScan.applyBySpan(plugin, source, violations, [coalKind], (node, span) -> {
			if (node.children.length != 2) return null;
			final left: QueryNode = node.children[0];
			final leftSpan: Null<Span> = left.span;
			return leftSpan == null ? null : { span: span, text: source.substring(leftSpan.from, leftSpan.to) };
		});
	}

}

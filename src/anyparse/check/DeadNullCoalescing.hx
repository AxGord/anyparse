package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.NullFlowScan.IdentOperand;
import anyparse.query.DeclaredNullity;
import anyparse.query.IndexScope;
import anyparse.query.SymbolIndex;
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
 * Under null-safety (`NullSafetyGate`) the compiler must see the proof too: dropping the fallback of an operand narrowed
 * only through a Bool local, an alias or a lone surviving `if` arm leaves `Cannot return nullable value`, so such a
 * finding keeps a `declineReason` and gets no edit (`NullFacts.nonNullVisible`).
 */
@:nullSafety(Strict)
final class DeadNullCoalescing implements Check implements ConfigAware {

	/** What dropping a fallback whose proof the compiler's null-safety does not share would do (`NullSafetyGate`). */
	private static inline final UNSEEN_CONSEQUENCE: String = ', so dropping the fallback would not compile';

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

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
		final index: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex(files, plugin);
		final gate: NullSafetyGate = new NullSafetyGate(_resolveConfig);
		return RunScan.collectWith(files, plugin, RunScan.typeInfoOf(plugin), (entry, root, typed, violations) -> {
			final types: DeclaredNullity = DeclaredNullity.of(entry.file, root, entry.source, shape, typed, plugin.typeSyntax, index);
			NullFlow.analyze(root, shape, entry.source, (node, facts) -> {
				if (node.kind != coalKind || node.children.length != 2) return;
				final left: Null<IdentOperand> = NullFlowScan.identOperand(node, node.children[0], ident);
				if (left == null) return;
				// Owned by `redundant-null-coalescing` when the declared type proves it.
				if (TypeResolver.isProvablyNonNull(left.operand, root, shape, types)) return;
				if (!facts.nonNull(left.name)) return;
				violations.push({
					file: entry.file,
					span: left.span,
					rule: 'dead-null-coalescing',
					severity: Severity.Info,
					message: 'right operand is dead — left operand is already non-null on this path',
					declineReason: gate.unseenProofReason(entry.file, root, left.span, shape, facts, left.name, UNSEEN_CONSEQUENCE)
				});
			});
		});
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final nullCoalesceKind: Null<String> = shape.nullCoalesceKind;
		if (nullCoalesceKind == null) return [];
		final coalKind: String = nullCoalesceKind;
		return CheckScan.applyBySpan(plugin, source, violations.filter(v -> v.declineReason == null), [coalKind], (node, span) -> {
			if (node.children.length != 2) return null;
			final left: QueryNode = node.children[0];
			final leftSpan: Null<Span> = left.span;
			return leftSpan == null ? null : { span: span, text: source.substring(leftSpan.from, leftSpan.to) };
		});
	}

}

package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.NullFlowScan.IdentOperand;
import anyparse.query.DeclaredNullity;
import anyparse.query.IndexScope;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

/**
 * Flags a null-safe access (`a?.b`) whose receiver is already non-null **by flow**
 * on every path reaching it — the `?.` can never short-circuit, so a plain `.` is
 * equivalent. The flow-only counterpart of `unnecessary-safe-nav`.
 *
 * ## Flow-only — complements `unnecessary-safe-nav`, never duplicates it
 *
 * Non-null-ness comes purely from `NullFlow`: an earlier `!= null` guard narrowing
 * this path (then-arm), an `== null` guard's else-arm, or a syntactically non-null
 * assignment. It skips any receiver the declared prover
 * `TypeResolver.isProvablyNonNull` already proves non-null — those belong to
 * `unnecessary-safe-nav`. So a redundant `?.` is reported exactly once.
 *
 * Conservative throughout (see `NullFlow`): every uncertainty collapses to
 * `Unknown`, so only a genuinely redundant `?.` is reported. `Severity.Info`;
 * `fix` rewrites `?.`→`.`, the same rewrite `unnecessary-safe-nav` applies. Under null-safety (`@:nullSafety`
 * in scope, or an oracle build that may enable it) the compiler must see the proof too, so a receiver whose
 * proof it does not follow keeps its finding with a `declineReason` and no edit (`NullFacts.nonNullVisible`).
 */
@:nullSafety(Strict)
final class DeadSafeNav implements Check implements ConfigAware {

	/** What a `.` rewrite of a proof the compiler's null-safety does not share would do (`NullSafetyGate.unseenProofReason`). */
	private static inline final UNSEEN_CONSEQUENCE: String = ', so a plain `.` would not compile';

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return 'dead-safe-nav';
	}

	public function description(): String {
		return 'a null-safe access (?.) whose receiver is already non-null on every path reaching it';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final safeNavKind: Null<String> = shape.nullSafeAccessKind;
		final identKind: Null<String> = shape.identKind;
		if (safeNavKind == null || identKind == null) return [];
		final navKind: String = safeNavKind;
		final ident: String = identKind;
		final gate: NullSafetyGate = new NullSafetyGate(_resolveConfig);
		final index: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex(files, plugin);
		return RunScan.collectWith(files, plugin, RunScan.typeInfoOf(plugin), (entry, root, typed, violations) -> {
			final types: DeclaredNullity = DeclaredNullity.of(entry.file, root, entry.source, shape, typed, plugin.typeSyntax, index);
			NullFlow.analyze(root, shape, entry.source, (node, facts) -> {
				if (node.kind != navKind || node.children.length != 1) return;
				final receiver: Null<IdentOperand> = NullFlowScan.identOperand(node, node.children[0], ident);
				if (receiver == null) return;
				// Owned by `unnecessary-safe-nav` when the declared type proves it.
				if (TypeResolver.isProvablyNonNull(receiver.operand, root, shape, types)) return;
				if (!facts.nonNull(receiver.name)) return;
				violations.push({
					file: entry.file,
					span: receiver.span,
					rule: 'dead-safe-nav',
					severity: Severity.Info,
					message: 'null-safe access is redundant — receiver is already non-null on this path',
					declineReason: gate.unseenProofReason(entry.file, root, receiver.span, shape, facts, receiver.name, UNSEEN_CONSEQUENCE)
				});
			});
		});
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final marker: String = '?.';
		return RunScan.spanEdits(violations, (violation, span) -> {
			final rel: Int = source.substring(span.from, span.to).indexOf(marker);
			if (violation.declineReason != null || rel < 0) return null;
			final at: Int = span.from + rel;
			return { span: new Span(at, at + marker.length), text: '.' };
		});
	}

}

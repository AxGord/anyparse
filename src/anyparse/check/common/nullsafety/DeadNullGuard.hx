package anyparse.check.common.nullsafety;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.RiskyFix;
import anyparse.check.common.nullsafety.NullFlowScan.IdentOperand;
import anyparse.query.DeclaredNullity;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;

/**
 * Flags a null comparison (`x != null` / `x == null`) whose operand is already
 * provably non-null **by flow** on every path reaching it — a dead guard: the
 * controlled branch is constant (always taken for `!=`, never for `==`).
 *
 * ## Flow-only — complements the point-wise checks, never duplicates them
 *
 * Non-null-ness is established by `NullFlow` purely from flow events: an earlier
 * `if (x != null)` narrowing this path, or a syntactically-non-null assignment
 * (`x = new T()`). It deliberately does NOT seed declared types, and it skips
 * any operand the declared prover `TypeResolver.isProvablyNonNull` already
 * proves non-null — those belong to `unnecessary-null-check`. So a redundant
 * null comparison is reported exactly once: by `unnecessary-null-check` when the
 * declared type proves it, by `dead-null-guard` when only the flow does.
 *
 * Conservative throughout (see `NullFlow`): every uncertainty — a join, a loop
 * back-edge, a closure-captured name, a macro subtree — collapses to `Unknown`,
 * so the check reports only a genuinely dead guard, never a load-bearing one.
 *
 * `Severity.Info`. A flow-dead guard can still be compiler-load-bearing: `@:nullSafety` narrows only through the forms
 * `NullFacts.nonNullVisible` lists, never through a fact laundered through a Bool local
 * (`final reads = x != null && flag; return reads && x != null ? x : y`), an alias copy, or what a lone surviving `if` arm
 * or a `try` proved. Where null-safety may be on (`NullSafetyGate`) such a guard keeps its finding with a
 * `declineReason` and no edit — removing it would leave `Cannot return nullable value`. The removal stays `RiskyFix`, so
 * every edit it does make lands only through the oracle typecheck-and-revert pipeline. `fix` conservatively drops the
 * dead guard where a safe span rewrite exists — unwrap / delete a sole-condition `if`, or drop a conjunct / disjunct
 * from a homogeneous `&&` / `||` chain — and refuses (leaves a finding) everywhere else. Its
 * proof is FLOW-based (`NullFlow`), never declared-type trust, so a default-null parameter
 * — which the declared prover now exempts too — reaches this check only when flow narrows it.
 */
@:nullSafety(Strict)
final class DeadNullGuard extends RuleBase implements RiskyFix implements ConfigAware {

	/** What removing a guard whose proof the compiler's null-safety does not share would do (`NullSafetyGate`). */
	private static inline final UNSEEN_CONSEQUENCE: String = ', so removing the guard would not compile';

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super('dead-null-guard', 'a null comparison whose operand is already non-null on every path reaching it', RuleCategory.NullSafety);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final provider: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		final index: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex(files, plugin);
		final gate: NullSafetyGate = new NullSafetyGate(_resolveConfig);
		return RunScan.collectWith(files, plugin, NullFlowScan.seamsOf(shape), (entry, root, s, violations) -> {
			final types: DeclaredNullity = DeclaredNullity.of(entry.file, root, entry.source, shape, provider, plugin.typeSyntax, index);
			NullFlow.analyze(root, shape, entry.source, (node, facts) -> {
				final compared: Null<IdentOperand> = NullFlowScan.nullComparedOperand(node, s);
				if (compared == null) return;
				// Owned by `unnecessary-null-check` when the declared type proves it — the SAME
				// predicate it reports on, so a value-typed operand the null-comparison variant
				// declines falls to this check's flow proof instead of between the two.
				if (TypeResolver.isProvablyNonNullAtNullComparison(compared.operand, root, shape, types)) return;
				if (!facts.nonNull(compared.name)) return;
				violations.push({
					file: entry.file,
					span: compared.span,
					rule: 'dead-null-guard',
					severity: Severity.Info,
					message: 'null check is redundant — operand is already non-null on this path',
					declineReason: gate.unseenProofReason(entry.file, root, compared.span, shape, facts, compared.name, UNSEEN_CONSEQUENCE)
				});
			});
		});
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return CheckScan.simplifyNullComparisonFixes(plugin, source, violations.filter(v -> v.declineReason == null));
	}

}

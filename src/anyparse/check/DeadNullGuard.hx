package anyparse.check;

import anyparse.check.Check.RiskyFix;
import anyparse.check.Check.Violation;
import anyparse.check.NullFlowScan.IdentOperand;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

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
 * `Severity.Info`. The removal is `RiskyFix`: a flow-dead guard can still be compiler-load-bearing (`@:nullSafety` narrowing
 * cannot see a fact laundered through a Bool local, e.g. `final ok = x != null && flag; if (ok) x.f`), so the fix lands only
 * through the oracle typecheck-and-revert pipeline. `fix` conservatively drops the dead guard where a safe span rewrite
 * exists — unwrap / delete a sole-condition `if`, or drop a conjunct / disjunct from a
 * homogeneous `&&` / `||` chain — and refuses (leaves a finding) everywhere else. Its
 * proof is FLOW-based (`NullFlow`), never declared-type trust, so a default-null parameter
 * — which the declared prover now exempts too — reaches this check only when flow narrows it.
 */
@:nullSafety(Strict)
final class DeadNullGuard implements Check implements RiskyFix {

	public function new() {}

	public function id(): String {
		return 'dead-null-guard';
	}

	public function description(): String {
		return 'a null comparison whose operand is already non-null on every path reaching it';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final provider: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		return RunScan.collectWith(files, plugin, NullFlowScan.seamsOf(shape), (entry, root, s, violations) -> {
			final declaredTypes: Map<Int, String> = provider != null ? provider.declaredTypes(entry.source) : [];
			NullFlow.analyze(root, shape, entry.source, (node, facts) -> {
				final compared: Null<IdentOperand> = NullFlowScan.nullComparedOperand(node, s);
				if (compared == null) return;
				// Owned by `unnecessary-null-check` when the declared type proves it — the SAME
				// predicate it reports on, so a value-typed operand the null-comparison variant
				// declines falls to this check's flow proof instead of between the two.
				if (TypeResolver.isProvablyNonNullAtNullComparison(compared.operand, root, shape, declaredTypes)) return;
				if (facts.nonNull(compared.name)) violations.push({
					file: entry.file,
					span: compared.span,
					rule: 'dead-null-guard',
					severity: Severity.Info,
					message: 'null check is redundant — operand is already non-null on this path'
				});
			});
		});
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return CheckScan.simplifyNullComparisonFixes(plugin, source, violations);
	}

}

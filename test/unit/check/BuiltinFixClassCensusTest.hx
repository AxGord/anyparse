package unit.check;

import anyparse.check.Check;
import anyparse.check.Linter;
import utest.Assert;
import utest.Test;

/**
 * The builtin fix census: which of `Linter.builtins()` declares a verified class, and how
 * many there are at all.
 *
 * ## Why this is pinned
 *
 * `--fix` runs a check's edits through one of two nets. A `RiskyFix` check is typechecked and
 * reverted per candidate (`FixVerifier`), and left report-only wholesale when no
 * `compilerOracle` is configured. EVERY other check is applied UNVERIFIED — and until this
 * slice the only thing behind them was `Cli.reconcileSafePass`, which returns at its first
 * line without an oracle. So the safe/risky split is the whole of the classification, it is a
 * DECLARATION rather than a measurement, and a new builtin joins the unverified side by
 * saying nothing. This test makes joining it deliberate.
 *
 * ## The measured half, and where it came from
 *
 * The declaration says nothing about what a fix DOES, so the class of each fix was measured
 * rather than read: every `Check.fix` / `fixGrouped` / `fixWithOracle` call site was
 * instrumented in a scratch build and `lint --all --fix` run over this project's `src` + `test`
 * and over a copy of Pony (869 files), once without an oracle and once with. 60 of the
 * builtins produced an edit at all — the rest never fired on that corpus, which is the honest
 * limit of a measured census.
 *
 * Of the 895 edits the two no-oracle arms produced, **12 SAFE rules emitted a pure deletion**
 * (`dead-code`, `dead-store`, `duplicate-case`, `join-array-pushes`, `join-single-use-local`,
 * `narrow-local-scope`, `prefer-static-extension`, `unnecessary-null-check`, `unused-import`,
 * `unused-local`, `unused-parameter`, `unused-private`) accounting for 182 edits, and 30 more
 * emitted a REPLACEMENT shorter than the span it covers — another 536. That is the number that
 * refused the obvious repair: demoting deleting safe fixes to report-only without an oracle
 * costs 20 % of the run's edits, `unused-import`'s 84 among them, and demoting the shrinking
 * ones as well costs 80 %.
 *
 * `DefiniteAssignmentGuard` is what landed instead: it refuses the one class of deleting edit
 * the language itself refuses, per check, with no compiler, and cost nothing measurable: Pony 869 files,
 * interleaved, base 29.6 / 29.9 s against this slice 30.0 / 30.1 s — inside the 0.4 s spread
 * of the identical binary — with both trees byte-identical at 697 edits in 210 files, and
 * anyparse src + test byte-identical at 106 edits in 43 files. Zero refusals on either.
 */
class BuiltinFixClassCensusTest extends Test {

	public function testTheBuiltinSetIsThisBig(): Void {
		// Shrinkage IS the acceptance test: a new builtin changes this number, and the author
		// then has to say which side of the verified/unverified split it joins.
		Assert.equals(179, Linter.builtins().length);
	}

	public function testTheseAreTheRiskyFixRules(): Void {
		// The ONLY builtins whose edits a compiler verifies before they land. Everything else
		// in `builtins()` is applied unverified when the run has no oracle.
		Assert.same([
			'avoid-dynamic',
			'dead-null-guard',
			'hoist-embedded-assignment',
			'prefer-case-guard',
			'prefer-enum-abstract',
			'prefer-exists',
			'prefer-inline',
			'prefer-interpolation',
			'prefer-map-type',
			'prefer-null-coalescing',
			'redundant-import',
			'shorten-type-ref',
			'unused-public-member'
		], idsImplementing(c -> c is RiskyFix));
	}

	public function testTheseAreTheOracleAssistedRules(): Void {
		Assert.same(['avoid-dynamic', 'explicit-local-type', 'explicit-type'], idsImplementing(c -> c is OracleAssisted));
	}

	public function testTheseRulesDeclareNoAutofixAtAll(): Void {
		Assert.same([
			'asymmetric-branch-braces',
			'complexity',
			'doc-coverage',
			'duplicate-code',
			'magic-number'
		], idsImplementing(c -> c is NoAutofix));
	}

	public function testDeadStoreIsOnTheUNVERIFIEDSide(): Void {
		// The one the campaign's corruption class came through: a fix that DELETES a local's
		// initializer, on the side of the split nothing typechecks. It is not a defect that it
		// is safe — its shape gate is real — but it is why the safe side needed a net of its own.
		final deadStore: Null<Check> = Linter.builtins().filter(c -> c.id() == 'dead-store')[0];
		Assert.notNull(deadStore);
		Assert.isFalse(deadStore is RiskyFix);
		Assert.isFalse(deadStore is NoAutofix);
	}

	/** The ids of every builtin matching `predicate`, sorted — the census's declared column. */
	private function idsImplementing(predicate: (Check) -> Bool): Array<String> {
		final ids: Array<String> = [for (check in Linter.builtins()) if (predicate(check)) check.id()];
		ids.sort((a, b) -> if (a < b)
			-1
		else if (a > b)
			1
		else
			0);
		return ids;
	}

}

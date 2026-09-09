package unit.cli;

import anyparse.check.Check;
import anyparse.check.Linter;
import anyparse.query.Cli.RuleFixOutcome;
import anyparse.query.LintFixSafePass;
import anyparse.query.cli.command.LintFixDriver;
import anyparse.query.cli.command.LintFixLedger;
import utest.Assert;
import utest.Test;

/**
 * What a `--fix` run says when it wrote NOTHING, which is the run it usually is.
 *
 * `--fix` behind a write op is scoped to the lines one edit touched, so it lands zero edits
 * most times it is asked — and it printed ~1450 bytes of rule accounting about them anyway:
 * the per-rule unfixed ledger, the never-asked list, and the census, every sentence of which
 * is a statement about what the run WROTE. Measured on one `hxq lint <one file> --fix
 * --no-oracle` with no edit to make: 1819 bytes of stderr, of which 206 was the summary line
 * that carries the whole verdict.
 *
 * So the accounting is gated on `edits > 0 || --verbose`, and the pin below is the pair — silent
 * on a zero-edit run, unchanged on a productive one. `LintFixSafePass.netNotice`'s
 * `--no-oracle` arm is the same shape and is asserted beside it: `--fix` on a write op passes
 * that flag for the reader, so narrating it back cost 161 bytes on every single one.
 */
@:nullSafety(Strict)
class LintFixQuietDefaultTest extends Test {

	/**
	 * The census is SILENT on a run that wrote nothing, and unchanged on one that wrote.
	 *
	 * Written as a pair on purpose: an empty result also passes when the ledger was empty, so
	 * the productive arm — same ledger, same checks, one edit — is what makes the quiet arm
	 * mean anything.
	 */
	@:pin('control')
	@:killer('M-LINT-FIX-CENSUS-UNGATED')
	public function testTheRuleAccountingWaitsForAnEditOrForVerbose(): Void {
		#if (sys || nodejs)
		final check: Null<Check> = Linter.byId('unused-local');
		if (check == null) {
			Assert.fail('unused-local is not registered');
			return;
		}
		final ledger: Map<String, RuleFixOutcome> = [];
		final row: RuleFixOutcome = LintFixDriver.ledgerFor(ledger, 'unused-local');
		row.reported = 2;
		row.declined = 2;
		Assert.equals(0, lines(ledger, check, 0, false).length, 'a run that wrote nothing has nothing to account for');
		Assert.isTrue(lines(ledger, check, 1, false).length > 0, 'a run that DID write still prints the whole block');
		Assert.isTrue(lines(ledger, check, 0, true).length > 0, '--verbose brings it back on a zero-edit run');
		// The same block, not a shortened one: the productive run's bytes did not change.
		Assert.equals(lines(ledger, check, 1, false).join(''), lines(ledger, check, 0, true).join(''));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The `--no-oracle` net notice waits for `--verbose`; the UNCONFIGURED one never does.
	 *
	 * The two are not equally worth saying. A reader who passed `--no-oracle` is being told
	 * about their own flag, and the run's summary line already carries both consequences the
	 * sentence states. A project that configured no `compilerOracle` at all is being told
	 * something it may not know, and the sentence names a remedy it has not taken — so that
	 * arm speaks whatever the verbosity.
	 */
	public function testOnlyTheFlagArmOfTheNetNoticeIsQuiet(): Void {
		Assert.isNull(LintFixSafePass.netNotice('build.hxml', true, false), 'the flag the reader just passed');
		Assert.stringContains('--no-oracle', LintFixSafePass.netNotice('build.hxml', true, true) ?? '');
		final unconfigured: Null<String> = LintFixSafePass.netNotice(null, false, false);
		Assert.stringContains('apqlint.json', unconfigured ?? '', 'the arm that names a remedy still speaks');
		Assert.isNull(LintFixSafePass.netNotice('build.hxml', false, false), 'a run WITH a net says nothing either way');
	}

	private static function lines(ledger: Map<String, RuleFixOutcome>, check: Check, fixedCount: Int, verbose: Bool): Array<String> {
		return LintFixLedger.ledgerLines(ledger, [check], [], [], false, fixedCount, verbose);
	}

}

package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.CompilerOracle.OracleOutcome;
import anyparse.query.LintFixSafePass;

/**
 * `lint --fix`'s safe-pass revert net, as a pure decision over two oracle measurements.
 *
 * The defect it replaces: `FixVerifier` takes its baseline AFTER the safe fixes are on
 * disk, so a run whose OWN fixes broke the build reported
 * `risky-fix skipped (oracle baseline does not typecheck)` — a statement about the tree
 * before `--fix`, which had been green. The insurance switched itself off at exactly the
 * moment it was needed, and the tree was left un-typecheckable with no hint of the cause.
 *
 * Measuring BEFORE the writes is what tells the two apart. The classifier below is the
 * whole of that judgement; keeping it free of IO is what lets every arm be exercised
 * without spawning a compiler (the suite asserts elsewhere that no oracle is spawned
 * unless a project configures one).
 */
class LintFixSafePassRevertTest extends Test {

	public function testGreenThenRedRevertsTheWholePass(): Void {
		switch LintFixSafePass.classify(OracleOutcome.Confirmed, OracleOutcome.Rejected('Cannot assign to final')) {
			case Revert(errors):
				Assert.equals('Cannot assign to final', errors);
			case other:
				Assert.fail('expected Revert, got $other');
		}
	}

	public function testGreenThenGreenProceeds(): Void {
		Assert.isTrue(isProceed(LintFixSafePass.classify(OracleOutcome.Confirmed, OracleOutcome.Confirmed)));
	}

	public function testAlreadyRedBaselineSaysSoAndKeepsTheWrites(): Void {
		// The case the OLD message claimed and almost never was. A second red verdict proves
		// nothing here, so the pass stands and the run says the net is off.
		switch LintFixSafePass.classify(OracleOutcome.Rejected('pre-existing'), null) {
			case NoNet(tail):
				Assert.stringContains('did NOT typecheck before --fix ran', tail);
			case other:
				Assert.fail('expected NoNet, got $other');
		}
	}

	public function testUnavailableBeforeMeansNoNet(): Void {
		switch LintFixSafePass.classify(OracleOutcome.Unavailable('no haxe'), null) {
			case NoNet(tail):
				Assert.stringContains('no haxe', tail);
			case other:
				Assert.fail('expected NoNet, got $other');
		}
	}

	public function testUnavailableAfterKeepsTheWritesRatherThanRevertingOnNoEvidence(): Void {
		switch LintFixSafePass.classify(OracleOutcome.Confirmed, OracleOutcome.Unavailable('spawn failed')) {
			case NoNet(tail):
				Assert.stringContains('could not close', tail);
			case other:
				Assert.fail('expected NoNet, got $other');
		}
	}

	public function testADeclinedSecondMeasurementProceeds(): Void {
		Assert.isTrue(isProceed(LintFixSafePass.classify(OracleOutcome.Confirmed, null)));
	}

	private function isProceed(decision: SafePassDecision): Bool {
		return switch decision {
			case Proceed: true;
			case _: false;
		};
	}

}

package unit.cli;

import anyparse.query.RunLedger;
import anyparse.query.cli.CliContext;

/** A command says what it says through the ledger its context carries: the run's own, else the latest run's. */
class CliContextLedgerTest extends Test {

	@:pin('control')
	@:killer('M-CONTEXT-LEDGER-IGNORED')
	public function testAContextCarriesTheLedgerItWasGiven(): Void {
		final own: RunLedger = RunLedger.begin();
		Assert.notEquals(own, RunLedger.begin());
		Assert.equals(own, new CliContext(false, false, null, null, own).ledger);
	}

	@:pin('guard')
	public function testAContextWithoutOneSharesTheLatestRunsLedger(): Void {
		Assert.equals(RunLedger.begin(), new CliContext(false).ledger);
	}

}

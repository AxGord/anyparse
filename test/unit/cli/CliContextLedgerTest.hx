package unit.cli;

import anyparse.query.RunLedger;
import anyparse.query.cli.CliContext;

/** A command says what it says through the ledger its context carries: the run's own, which every context of the run shares. */
class CliContextLedgerTest extends Test {

	@:pin('control')
	@:killer('M-CONTEXT-LEDGER-IGNORED')
	public function testAContextCarriesTheLedgerItWasGiven(): Void {
		final own: RunLedger = RunLedger.begin();
		Assert.notEquals(own, RunLedger.begin());
		Assert.equals(own, new CliContext(false, own).ledger);
	}

	@:pin('guard')
	public function testTheContextsOfOneRunShareItsLedger(): Void {
		final own: RunLedger = RunLedger.begin();
		Assert.equals(new CliContext(false, own).ledger, new CliContext(true, own).ledger);
	}

}

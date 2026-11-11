package unit.query;

import anyparse.query.RunLedger;

/** What a run says is its ledger's: each run owns one, and a caller with none shares the latest. */
class RunLedgerTest extends Test {

	@:pin('control')
	@:killer('M-RUN-LEDGER-BEGIN-REUSES')
	public function testEachRunOwnsAnEmptyLedgerOfItsOwn(): Void {
		final first: RunLedger = RunLedger.begin();
		Assert.isTrue(first.first('topic', 'key'));
		Assert.isFalse(first.first('topic', 'key'));
		final second: RunLedger = RunLedger.begin();
		Assert.isFalse(second.said('topic', 'key'), 'a later run starts with nothing said');
		Assert.same([], second.keysOf('topic'));
		Assert.isTrue(first.said('topic', 'key'), 'and the earlier run keeps its own record');
		Assert.same(['key'], first.keysOf('topic'));
	}

	@:pin('control')
	@:killer('M-RUN-LEDGER-BEGIN-ANSWERS-OTHER')
	public function testTheFallbackIsTheLedgerOfTheLatestRun(): Void {
		final ledger: RunLedger = RunLedger.begin();
		Assert.equals(ledger, RunLedger.fallback());
		Assert.isTrue(RunLedger.fallback().first('topic', 'shared'));
		Assert.isTrue(ledger.said('topic', 'shared'), 'a context-less caller says through the run\'s own ledger');
	}

}

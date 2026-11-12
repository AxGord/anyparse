package unit.query;

import anyparse.query.RunLedger;

/**
 * What a run says is its ledger's: each ledger starts empty and records only what is asked through it.
 */
class RunLedgerTest extends Test {

	@:pin('guard')
	public function testEachLedgerStartsEmptyAndKeepsItsOwnRecord(): Void {
		final first: RunLedger = new RunLedger();
		Assert.isTrue(first.first('topic', 'key'));
		Assert.isFalse(first.first('topic', 'key'));
		final second: RunLedger = new RunLedger();
		Assert.isFalse(second.said('topic', 'key'), 'a later ledger starts with nothing said');
		Assert.same([], second.keysOf('topic'));
		Assert.isTrue(first.said('topic', 'key'), 'and the earlier ledger keeps its own record');
		Assert.same(['key'], first.keysOf('topic'));
	}

}

package unit.proc;

/** The answer the process driver writes: `ProcessSpawn.runsOf` reads it as runs in job order, and refuses what is not that shape. */
class ProcessRunsDocumentTest extends Test {

	public function testRunsComeBackInTheOrderTheyAreWritten(): Void {
		final runs: Null<Array<ProcessRun>> = ProcessSpawn.runsOf(
			'{"runs":[{"status":0,"out":"a\\n","err":"","failure":"","overflowed":false,"cancelled":false},'
			+ '{"out":"","err":"e","failure":"timed out","overflowed":true,"cancelled":true,"unstarted":true}]}'
		);
		if (runs == null) {
			Assert.fail('no runs');
			return;
		}
		Assert.equals(2, runs.length);
		Assert.equals(0, runs[0].status);
		Assert.equals('a\n', runs[0].out);
		Assert.equals(false, runs[0].cancelled);
		Assert.isNull(runs[0].unstarted);
		Assert.isNull(runs[1].status);
		Assert.equals('timed out', runs[1].failure);
		Assert.isTrue(runs[1].overflowed);
		Assert.equals(true, runs[1].unstarted);
	}

	public function testNoJobsIsNoRuns(): Void {
		Assert.same([], ProcessSpawn.runsOf('{"runs":[]}'));
	}

	/** The driver wrote a bare array once; a reader of the envelope must not take it for an answer. */
	public function testWhatIsNotTheDriversShapeIsNoAnswer(): Void {
		for (text in [
			'[]',
			'',
			'{"runs":',
			'{"runs":[{"status":0,"out":"","err":"","failure":""}]}',
			'{"runs":[{"status":"0","out":"","err":"","failure":"","overflowed":false}]}',
			'{"runs":[{"status":0,"out":1,"err":"","failure":"","overflowed":false}]}',
			'{"other":[]}'
		]) Assert.isNull(ProcessSpawn.runsOf(text), text);
	}

}

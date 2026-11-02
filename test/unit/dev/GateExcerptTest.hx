package unit.dev;

import dev.GateExcerpt;
import dev.Shard;
import utest.Assert;
import utest.Test;

/** `dev.GateExcerpt`: the lines a failed gate row prints under the table are the ones that decide it. */
@:nullSafety(Strict)
final class GateExcerptTest extends Test {

	public function testTheRedShardsOfASuiteTranscriptAreKeptAndTheGreenOnesAreNot(): Void {
		final lines: Array<String> = [
			'shard 0:  200 classes / 900 tests /  4000 assertions / 0 failures / 0 errors (exit 0) in 12.1s',
			'shard 1:  200 classes / 900 tests /  4000 assertions / 2 failures / 0 errors (exit 1) in 12.1s',
			'  shard 1 first failure: unit.AThing.testIt  line:12  expected 1 but it is 2',
			'  shard 1 failing: unit.AThing.testIt, unit.BThing.testThat',
			'--- suite-shard: 400 classes / 1800 tests / 8000 assertions / 2 failures / 0 errors in 12.2s across 2 shards ---',
			'suite-shard: FAILED — shard 1 is red (2 failures / 0 errors)'
		];
		Assert.same([lines[2], lines[3], lines[5]], GateExcerpt.suite(lines));
	}

	public function testAShardThatDidNotFinishAndAnUnreadableTranscriptAreShown(): Void {
		final partial: Array<String> = [
			'shard 0: 10 classes / 5 tests / 9 assertions / 0 failures / 0 errors (exit 1) '
				+ 'in 1.0s  <-- did NOT finish: these counts are partial',
			'suite-shard: FAILED — shard 0 exited 1 with no failing test in its report — it did not finish'
		];
		Assert.same(partial, GateExcerpt.suite(partial));
		Assert.same(['all', 'quiet'], GateExcerpt.suite(['all', 'quiet']), 'no red line: the transcript\'s last lines');
	}

	public function testALintDiffReportYieldsItsAddedRowsAndOnRequestItsRemovedOnes(): Void {
		final report: String = [
			'lint-diff: 3 findings (base 2, net +1) — 2 added / 1 removed',
			'  by rule      r 1->2 (+1 -0)',
			'  + a/B.hx  r  something new',
			'  + a/C.hx  r  another',
			'  - a/D.hx  r  gone'
		].join('\n');
		Assert.same(['+ a/B.hx  r  something new', '+ a/C.hx  r  another'], GateExcerpt.lintRows(report, false));
		Assert.same(['+ a/B.hx  r  something new', '+ a/C.hx  r  another', '- a/D.hx  r  gone'], GateExcerpt.lintRows(report, true));
	}

	public function testTheArmsThatHeldAreLeftOut(): Void {
		final log: String = [
			'schema: 3 arm(s) composed into one build',
			'KILLED     M-A filter=unit.ATest 1 tests failed / 2 assertions: unit.ATest.testA',
			'SURVIVED   M-B filter=unit.BTest',
			'MISMATCH   M-C filter=unit.CTest killer named another test',
			'3 tracks: 1 killed, 1 survived, 1 mismatch, 0 error'
		].join('\n');
		Assert.same([
			'SURVIVED   M-B filter=unit.BTest',
			'MISMATCH   M-C filter=unit.CTest killer named another test'
		], GateExcerpt.arms(log));
		Assert.same(
			['dev mutation-arm: the build failed with an error'],
			GateExcerpt.arms('workroot: x\ndev mutation-arm: the build failed with an error')
		);
	}

	public function testACompilerErrorKeepsItsContinuationAndDropsWarnings(): Void {
		final log: String = [
			'src/A.hx:3: characters 1-2 : Warning : Potential typo',
			'tools/src/dev/X.hx:10: characters 5-9 : Int should be String',
			'tools/src/dev/X.hx:10: characters 5-9 : ... For function argument \'cb\'',
			'building'
		].join('\n');
		Assert.same([log.split('\n')[1], log.split('\n')[2]], GateExcerpt.compile(log));
	}

	public function testTheLineADevShardPrintsForRedShardsIsKept(): Void {
		final printed: String = '  shard 1 ' + Shard.failingLine(['a.A.t1', 'a.A.t2']);
		Assert.same([printed], GateExcerpt.suite(['shard 0: ok', printed]));
	}

	public function testARedShardNamesAtMostFiveFailingTests(): Void {
		Assert.equals('failing: a.A.t1, a.A.t2', Shard.failingLine(['a.A.t1', 'a.A.t2']));
		Assert.equals('failing: n.1, n.2, n.3, n.4, n.5, … +2 more', Shard.failingLine([for (i in 1...8) 'n.$i']));
	}

}

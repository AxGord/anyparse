package unit.dev;

import dev.Battery;
import devkit.Summary.Outcome;
import devkit.TempDir;
import js.node.Fs.Fs;
import sys.io.File;
import utest.Assert;
import utest.Test;

/**
 * `dev battery`'s readings: which snapshot a run compares against, the counts it reads off the suite and the sweep, the
 * corpus gate, the cross-config one-pass set and the lines that close a run. The steps themselves run the project's own
 * tools, and the parity with the script it replaced is a reading of one tree, not a test.
 */
@:nullSafety(Strict)
final class BatteryTest extends Test {

	public function testTheBaseIsTheNewestSnapshotByMtimeNotByName(): Void {
		TempDir.with(dir -> {
			for (key in ['ffff0000', '00000000']) File.saveContent(dir.file('$key-suite.txt'), '1 2\n');
			File.saveContent(dir.file('zzzz9999-anyparse.json'), '{}');
			Fs.utimesSync(dir.file('ffff0000-suite.txt'), Date.fromTime(1000000), Date.fromTime(1000000));
			Fs.utimesSync(dir.file('00000000-suite.txt'), Date.fromTime(2000000), Date.fromTime(2000000));
			Assert.equals('00000000', Battery.newestBase(dir.path));
		});
		TempDir.with(dir -> Assert.isNull(Battery.newestBase(dir.path), 'a first run has no base'));
	}

	public function testASnapshotSuiteLineIsTwoCounts(): Void {
		TempDir.with(dir -> {
			File.saveContent(dir.file('k-suite.txt'), '18380 76645\n');
			Assert.same([18380, 76645], Battery.suiteCounts(dir.file('k-suite.txt')));
			File.saveContent(dir.file('bad-suite.txt'), 'x\n');
			Assert.isNull(Battery.suiteCounts(dir.file('bad-suite.txt')));
			Assert.isNull(Battery.suiteCounts(dir.file('none-suite.txt')));
		});
	}

	public function testTheSweepCountsAreReadOffItsSummaryLine(): Void {
		final text: String = '782 pass / 120 fail / 42 skip-parse / 0 skip-write / 1 skip-config / 1 malformed (total 946)\n'
			+ '  Δpass 0 / Δfail 0 / Δskip-parse 0  vs base.json (782 / 120 / 42)\n';
		Assert.same([782, 120, 42], Battery.sweepCounts(text));
		Assert.same([0, 0, 0], Battery.sweepCounts('no summary here\n'));
	}

	public function testOnlyASignedPositiveFailDeltaIsACorpusRegression(): Void {
		Assert.isTrue(Battery.corpusRegressed('Δfail +6'));
		Assert.isFalse(Battery.corpusRegressed('Δfail 0'));
		Assert.isFalse(Battery.corpusRegressed('Δfail -4'));
		Assert.isFalse(Battery.corpusRegressed('Δfail +0'));
	}

	public function testTheOnePassSetIsTheFilesUnderTheScratchRootSorted(): Void {
		final err: String = [
			'apq fmt: /w/xconfig/src/b/B.hx: the writer needed 2 rewrites to reach its fixed point',
			'apq fmt: /w/xconfig/src/a/A.hx: the writer needed 2 rewrites to reach its fixed point',
			'apq fmt: /elsewhere/C.hx: the writer needed 2 rewrites to reach its fixed point',
			'apq fmt --list: 3 of 9 file(s) would be rewritten'
		].join('\n');
		Assert.same(['src/a/A.hx', 'src/b/B.hx'], Battery.onePassSet(err, '/w/xconfig'));
	}

	public function testTheSetMovesNameEveryFileGoneAndJoined(): Void {
		Assert.same([], Battery.setMoves(['a', 'b'], ['a', 'b']));
		Assert.same(['- a', '+ c'], Battery.setMoves(['a', 'b'], ['b', 'c']));
	}

	@:pin('control')
	@:killer('M-BATTERY-BLAST-EXIT2-WAIVED')
	public function testAllowBlastWaivesMovementButNeverAComparisonThatCouldNotRun(): Void {
		Assert.isTrue(Battery.blastOutcome([{ label: 'anyparse', status: 0 }], false, 'k').match(Passed));
		Assert.isTrue(Battery.blastOutcome([{ label: 'anyparse', status: 1 }], false, 'k').match(Failed(_)), 'movement fails the gate');
		Assert.isTrue(Battery.blastOutcome([{ label: 'anyparse', status: 1 }], true, 'k').match(Passed), '--allow-blast waives movement');
		Assert.isTrue(
			Battery.blastOutcome([{ label: 'anyparse', status: 2 }], true, 'k').match(Failed(_)), 'a comparison that could not run'
		);
		Assert.isTrue(Battery.blastOutcome([{ label: 'client', status: null }], true, 'k').match(Failed(_)), 'a lint-diff with no status');
		Assert.isTrue(Battery.blastOutcome([], false, null).match(Skipped(_)), 'no base snapshot compared');
	}

	@:pin('guard')
	public function testAFailedRowNamedByAllowIsWaivedAndNoOtherIs(): Void {
		final red: Outcome = Failed('8 fixtures changed');
		Assert.equals('8 fixtures changed', Battery.waiver('corpus', ['corpus'], red));
		Assert.isNull(Battery.waiver('lint', ['corpus'], red), 'a row not named keeps its failure');
		Assert.isNull(Battery.waiver('corpus', [], red));
		Assert.isNull(Battery.waiver('corpus', ['corpus'], NotRun('the suite was red')), 'a row that did not run is not waived');
		Assert.isNull(Battery.waiver('corpus', ['corpus'], Passed));
		Assert.isTrue(Battery.rowNames().contains('corpus') && Battery.rowNames().contains('fmt xconfig'));
	}

	public function testTheClosingLinesCarryTheBaseDeltaAndACorpusNotRun(): Void {
		final readings: Map<String, Int> = ['tests' => 12, 'assertions' => 40];
		Assert.same(['suite  12 tests / 40 assertions', 'corpus not run'], Battery.totalsLines(readings, null, null));
		readings['sweep-pass'] = 7;
		readings['sweep-fail'] = 2;
		readings['sweep-skip'] = 1;
		Assert.same([
			'suite  12 tests / 40 assertions (base abc: 10 / 41, delta +2 / -1)',
			'corpus 7 pass / 2 fail / 1 skip-parse'
		], Battery.totalsLines(readings, 'abc', [10, 41]));
	}

	public function testNoJvmSkipsTheProbeWithoutAskingGit(): Void {
		Assert.equals('--no-jvm', Battery.jvmSkip('/nonexistent', null, false));
		Assert.equals('no baseline commit to diff the core against', Battery.jvmSkip('/nonexistent', null, null));
	}

}

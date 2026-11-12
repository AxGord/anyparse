package unit.devkit;

import devkit.Branches;
import devkit.Command;
import devkit.Lease;
import devkit.LeaseHistory;
import devkit.Summary;
import devkit.TempDir;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

using Lambda;
using StringTools;

/**
 * `devkit.LeaseHistory`: the recorded runs of a leased command become the per-size seconds of its next ask, only from sizes run
 * often enough, the sizes never run from the curve through those that were, and the file keeps a bounded tail.
 */
@:nullSafety(Strict)
final class LeaseHistoryTest extends Test {

	private static inline final MS: Int = 1000;

	@:pin('control')
	@:killer('M-LEASEHISTORY-ONE-SIZE-NO-CURVE')
	public function testNoHistoryOrOneSizeMakesNoCurve(): Void {
		TempDir.with(dir -> {
			final history: LeaseHistory = new LeaseHistory(dir.file('h.tsv'));
			Assert.isNull(history.seconds('suite', 2, 4), 'no file');
			runs(history, 'suite', 2, 100, 3);
			Assert.isNull(history.seconds('suite', 2, 4), 'one size measured');
			Assert.isNull(Lease.estimateOf(Branches.heavyAsk(2, 4, history, 'suite')), 'the lease then names no estimate');
		});
	}

	@:pin('control')
	@:killer('M-LEASEHISTORY-MIN-RUNS')
	public function testASizeRunTooFewTimesIsNotMeasured(): Void {
		TempDir.with(dir -> {
			final history: LeaseHistory = new LeaseHistory(dir.file('h.tsv'));
			runs(history, 'suite', 2, 100, LeaseHistory.MIN_RUNS);
			runs(history, 'suite', 4, 60, LeaseHistory.MIN_RUNS - 1);
			Assert.isNull(history.seconds('suite', 2, 4));
		});
	}

	@:pin('control')
	@:killer('M-LEASEHISTORY-FIT-FILL')
	public function testTwoMeasuredSizesMakeAFullCurve(): Void {
		TempDir.with(dir -> {
			final history: LeaseHistory = new LeaseHistory(dir.file('h.tsv'));
			runs(history, 'suite', 2, 100, 3);
			runs(history, 'suite', 4, 60, 3);
			final seconds: Map<Int, Int> = history.seconds('suite', 2, 4) ?? [];
			Assert.equals(100, seconds[2]);
			Assert.equals(60, seconds[4]);
			Assert.equals(74, seconds[3], 'the size never run: a + b / k through the two measured');
			Assert.equals('2:100,3:74,4:60', Lease.estimateOf(Branches.heavyAsk(2, 4, history, 'suite')));
			Assert.isNull(history.seconds('other', 2, 4), 'another key has no runs');
		});
	}

	@:pin('control')
	@:killer('M-LEASEHISTORY-RECENT')
	public function testOnlyTheLatestRunsOfASizeCount(): Void {
		TempDir.with(dir -> {
			final history: LeaseHistory = new LeaseHistory(dir.file('h.tsv'));
			runs(history, 'suite', 2, 9999, 2);
			runs(history, 'suite', 2, 10, LeaseHistory.RECENT);
			runs(history, 'suite', 3, 10, 3);
			final seconds: Map<Int, Int> = history.seconds('suite', 2, 3) ?? [];
			Assert.equals(10, seconds[2]);
		});
	}

	@:pin('control')
	@:killer('M-LEASEHISTORY-BOUND')
	public function testTheFileKeepsABoundedTail(): Void {
		TempDir.with(dir -> {
			final file: String = dir.file('h.tsv');
			final history: LeaseHistory = new LeaseHistory(file);
			for (i in 0...LeaseHistory.MAX_LINES + 20) history.record('key$i', 2, MS);
			final kept: Array<String> = File.getContent(file).split('\n').filter(line -> line != '');
			Assert.equals(LeaseHistory.MAX_LINES, kept.length);
			Assert.equals('key20\t2\t$MS', kept[0], 'the oldest went');
			Assert.equals('key${LeaseHistory.MAX_LINES + 19}\t2\t$MS', kept[kept.length - 1]);
		});
	}

	@:pin('control')
	@:killer('M-LEASEHISTORY-SERIES-BOUND')
	public function testACompactionKeepsTheLatestRunsOfEachSeries(): Void {
		final lines: Array<String> = [for (i in 0...LeaseHistory.RECENT + 5) 'a\t2\t$i'].concat(['b\t2\t1']);
		final kept: Array<String> = LeaseHistory.bounded(lines);
		Assert.equals(LeaseHistory.RECENT + 1, kept.length);
		Assert.equals('a\t2\t5', kept[0]);
		Assert.equals('b\t2\t1', kept[kept.length - 1]);
	}

	@:pin('control')
	@:killer('M-LEASEHISTORY-KEY')
	public function testTheKeyOfALabelDropsTheRunIds(): Void {
		Assert.equals('battery * suite,corpus', LeaseHistory.keyOf('battery 0282a792b suite,corpus'));
		Assert.equals('slice-gate * suite', LeaseHistory.keyOf('slice-gate LEASE-TIMING-HISTORY suite'));
		Assert.equals('post-land *', LeaseHistory.keyOf('post-land fedcba98'));
		Assert.equals('arm-sweep', LeaseHistory.keyOf(' arm-sweep '));
	}

	public function testANonPositiveReadingIsNotRecorded(): Void {
		TempDir.with(dir -> {
			final file: String = dir.file('h.tsv');
			final history: LeaseHistory = new LeaseHistory(file);
			history.record('suite', 0, MS);
			history.record('suite', 2, 0);
			history.recordLived('suite', null);
			Assert.isFalse(FileSystem.exists(file));
		});
	}

	@:pin('control')
	@:killer('M-BRANCHES-HISTORY-ASK')
	@:killer('M-BRANCHES-HEAVY-ASK-CURVE')
	public function testTheHeavyBranchAsksWithTheCurveOfItsKeyAcrossCommits(): Void {
		TempDir.with(dir -> {
			final history: LeaseHistory = new LeaseHistory(dir.file('h.tsv'));
			final key: String = Branches.timingKey('battery fedcba98', ['suite', 'corpus']);
			runs(history, key, 2, 100, 3);
			runs(history, key, 6, 40, 3);
			final take: (
				String, Null<LeaseHistory>
			) -> Array<String> = (head, known) ->
				Branches.leased(
					Own('/p/scripts/wf-run', 10), [['suite', 'corpus'], ['lint']],
					rows -> rows[0] == 'suite' ? null : 1, _ -> Command.of(['node', 'dev.js']), 'battery $head', known
				)(['suite', 'corpus']).argv;
			Assert.isTrue(
				take('0123abcd', history).exists(word -> word.startsWith('--est-by-threads=2:100,')), 'another commit, the same key'
			);
			Assert.isFalse(take('0123abcd', null).exists(word -> word.startsWith('--est-by-threads')), 'no history, no flag');
		});
	}

	@:pin('control')
	@:killer('M-BRANCHES-RECORD-FIT')
	public function testAFitBranchRecordsItsTimeOnTheThreadsItWasGranted(): Void {
		TempDir.with(dir -> {
			final file: String = dir.file('h.tsv');
			final history: LeaseHistory = new LeaseHistory(file);
			final fit: Summary = new Summary();
			fit.add('suite', Passed, 1);
			fit.add('corpus', Skipped('no sweep'), 0);
			final red: Summary = new Summary();
			red.add('suite', Failed('x'), 1);
			Branches.record(history, 'battery fedcba98', ['suite', 'corpus'], null, fit);
			Branches.record(history, 'battery fedcba98', ['suite', 'corpus'], 4, red);
			Assert.isFalse(FileSystem.exists(file), 'no grant or a red step: nothing recorded');
			Branches.record(history, 'battery fedcba98', ['suite', 'corpus'], 4, fit);
			final lines: Array<String> = File.getContent(file).split('\n').filter(line -> line != '');
			Assert.equals(1, lines.length);
			Assert.isTrue(lines[0].startsWith('battery * suite,corpus\t4\t'));
		});
	}

	/** `count` finished runs of `key` on `threads` threads that took `seconds` each. */
	private static function runs(history: LeaseHistory, key: String, threads: Int, seconds: Int, count: Int): Void {
		for (_ in 0...count) history.record(key, threads, seconds * MS);
	}

}

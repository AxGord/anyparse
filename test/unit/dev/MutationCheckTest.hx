package unit.dev;

import dev.MutationCheck;
import devkit.TempDir;
import sys.io.File;
import utest.Assert;
import utest.Test;

/**
 * `dev mutation-check`'s own half: the manifest it reads (every refusal before a slot is made), the default job count,
 * the report row and the timing line. A track's work is `MutationSlotTest`'s.
 */
@:nullSafety(Strict)
final class MutationCheckTest extends Test {

	public function testAManifestLineIsFourFieldsTheLastKeepingItsBars(): Void {
		final rows: Array<TrackRow> =
			parsed('# a comment\n\n  A-1 | p.patch | unit.X | unit.X.testA,unit.X.test|B  \nB | /abs.patch | ALL |\n');
		Assert.equals(2, rows.length);
		Assert.same({
			name: 'A-1',
			patch: '/m/p.patch',
			filter: 'unit.X',
			expected: 'unit.X.testA,unit.X.test|B'
		}, rows[0]);
		Assert.same({
			name: 'B',
			patch: '/abs.patch',
			filter: 'ALL',
			expected: ''
		}, rows[1], 'an absolute patch path passes through');
	}

	public function testAMalformedLineIsRefusedByItsNumber(): Void {
		Assert.equals('m:2: expected 4 \'|\'-separated fields', refusal('\nA | p | f\n'));
		Assert.equals('m:1: bad track name \'a b\' (allowed: A-Za-z0-9_.-)', refusal('a b | p | f | e\n'));
		Assert.equals('m:1: track \'A\' has no patch file', refusal('A |  | f | e\n'));
		Assert.equals('m:1: track \'A\' has an empty APQ_TEST filter (use ALL for the whole suite)', refusal('A | p |  | e\n'));
	}

	public function testTheDefaultJobsAreBoundByMemoryAndSpareTwoCores(): Void {
		final gib: Float = 1024 * 1024 * 1024;
		Assert.equals(12, MutationCheck.defaultJobs(16, 64 * gib));
		Assert.equals(6, MutationCheck.defaultJobs(16, 32 * gib + 1), 'memory binds: five GiB a job');
		Assert.equals(1, MutationCheck.defaultJobs(2, 64 * gib), 'never fewer than one');
		Assert.equals(1, MutationCheck.defaultJobs(8, 4 * gib));
	}

	public function testARefusedManifestRunsNothing(): Void {
		TempDir.with(dir -> {
			final manifest: String = dir.file('manifest');
			Assert.equals(2, run(dir.file('nothing')), 'no manifest');
			File.saveContent(manifest, '# only a comment\n');
			Assert.equals(2, run(manifest), 'no tracks');
			File.saveContent(dir.file('p.patch'), '');
			File.saveContent(manifest, 'A | p.patch | ALL |\nA | p.patch | ALL |\n');
			Assert.equals(2, run(manifest), 'a duplicate name');
			File.saveContent(manifest, 'A | missing.patch | ALL |\n');
			Assert.equals(2, run(manifest), 'a missing patch');
			File.saveContent(manifest, 'A | p.patch | ALL |\n');
			for (jobs in ['0', '00', '-1', 'two']) Assert.equals(2, run(manifest, jobs), '--jobs $jobs');
		});
	}

	public function testAReportRowPadsItsColumns(): Void {
		Assert.equals(
			'KILLED     M-X                  filter=unit.A         1 tests failed',
			MutationCheck.reportRow('KILLED', 'M-X', 'unit.A', '1 tests failed')
		);
		Assert.equals(
			'SURVIVED   M-A-VERY-LONG-ARM-NAME filter=unit.SomeLongClassTest d',
			MutationCheck.reportRow('SURVIVED', 'M-A-VERY-LONG-ARM-NAME', 'unit.SomeLongClassTest', 'd'),
			'a column wider than its pad is never cut'
		);
	}

	public function testTheTimingLineSumsEachBuildKind(): Void {
		Assert.isNull(MutationCheck.timingLine([]));
		Assert.equals(
			'timing: warm builds 2 (mean 15s), schema builds 1 (mean 0s), suite runs 3 (mean 4s), 2 answered killer-first',
			MutationCheck.timingLine(['schema 0 3 killers\n', 'warm 10 2 killers\n', 'warm 20 7 sliced\n'])
		);
		Assert.equals(
			'timing: cold builds 1 (mean 30s), suite runs 0 (mean 0s)', MutationCheck.timingLine(['cold 30\n']), 'a build-only record'
		);
	}

	public function testALeaseBoundsTheDefaultJobsAndAnExplicitAsk(): Void {
		final gib: Float = 1024 * 1024 * 1024;
		Assert.equals(4, MutationCheck.defaultJobs(16, 64 * gib, 4), 'a lease replaces the cores');
		Assert.equals(2, MutationCheck.defaultJobs(16, 12 * gib, 4), 'memory still binds under a lease');
		Assert.equals(1, MutationCheck.defaultJobs(16, 64 * gib, 1));
		Assert.same(Count(12, null), MutationCheck.jobsFor(null, null, 16, 64 * gib), 'no lease, no ask: the machine default');
		Assert.same(Count(4, null), MutationCheck.jobsFor(null, 4, 16, 64 * gib), 'no ask under a lease: the lease');
		Assert.same(Count(3, null), MutationCheck.jobsFor('3', 4, 16, 64 * gib), 'an ask within the lease stands');
		Assert.same(Count(4, '--jobs 12 exceeds the pool lease of 4 thread(s): running 4'), MutationCheck.jobsFor('12', 4, 16, 64 * gib));
		Assert.same(Count(12, null), MutationCheck.jobsFor('12', null, 16, 64 * gib), 'outside a lease the ask is not clamped');
	}

	public function testAJobsAskThatIsNoPositiveIntegerIsRefusedWhateverTheLease(): Void {
		for (asked in ['0', '00', '-1', 'two']) for (held in [null, 4])
			Assert.same(Unusable('--jobs must be a positive integer, got \'$asked\''), MutationCheck.jobsFor(asked, held, 16, 1e12));
	}

	private static function parsed(text: String): Array<TrackRow> {
		return switch MutationCheck.parseManifest(text, 'm', '/m') {
			case Rows(rows): rows;
			case Refused(why): throw why;
		};
	}

	private static function refusal(text: String): String {
		return switch MutationCheck.parseManifest(text, 'm', '/m') {
			case Rows(_): 'accepted';
			case Refused(why): why;
		};
	}

	private static function run(manifest: String, ?jobs: String): Int {
		return MutationCheck.run({
			repo: '/nonexistent',
			manifest: manifest,
			jobs: jobs,
			keep: false,
			buildOnly: false,
			killerFirst: false,
			schema: null,
			base: 'HEAD'
		});
	}

}

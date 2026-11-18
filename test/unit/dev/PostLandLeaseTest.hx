package unit.dev;

import dev.DetachedRow;
import dev.PostLand;
import dev.Shard;
import devkit.Command;
import devkit.ExecLedger;
import devkit.Lease;
import devkit.LeaseHistory;
import devkit.TempDir;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using Lambda;
using StringTools;

/**
 * `dev.PostLand` takes a lease for each phase of a run, sized to what that phase runs, and leaves a ledger row for each.
 */
@:nullSafety(Strict)
final class PostLandLeaseTest extends Test {

	@:pin('control')
	@:killer('M-POSTLAND-LEASED-HISTORY')
	public function testTheSuitePhasesLeaseCarriesTheCurveOfItsEarlierRuns(): Void {
		TempDir.with(dir -> {
			final history: LeaseHistory = new LeaseHistory(dir.file('h.tsv'));
			for (_ in 0...LeaseHistory.MIN_RUNS) {
				history.record(LeaseHistory.keyOf('post-land-shard fedcba98'), 2, 100 * 1000);
				history.record(LeaseHistory.keyOf('post-land-shard fedcba98'), Shard.DEFAULT_SHARDS, 60 * 1000);
			}
			final words: Command = Command.of(['node', 'dev.js']);
			final argv: Array<String> = PostLand.leased(Own('/p/scripts/wf-run', 10), words, 'post-land-shard 0123abcd', history).argv;
			Assert.isTrue(argv.exists(word -> word.startsWith('--est-by-threads=2:100,')));
			Assert.isTrue(argv.contains('--priority=0'));
			final bare: Array<String> = PostLand.leased(Own('/p/scripts/wf-run', 10), words, 'baseline-warm 0123abcd').argv;
			Assert.isFalse(bare.exists(word -> word.startsWith('--est-by-threads')));
		});
	}

	@:pin('control')
	@:killer('M-POSTLAND-LINT-LEASE-SHARE')
	@:killer('M-POSTLAND-LINT-CORES-ONE')
	public function testTheWholeLintIsLeasedOneProcessOnTheEnginesCpus(): Void {
		final lint: Command = Command.of(['hxq', 'lint']);
		final argv: Array<String> = PostLand.lintLeased(Own('/p/scripts/wf-run', 10), lint, 'post-land-lint 0123abcd').argv;
		Assert.equals('${Lease.NODE_CORES}', argv[argv.indexOf('--threads') + 1]);
		Assert.isFalse(argv.exists(word -> word.startsWith('--wait-full')));
		Assert.same(['hxq', 'lint'], PostLand.lintLeased(Unpooled, lint, 'post-land-lint 0123abcd').argv);
	}

	@:pin('control')
	@:killer('M-POSTLAND-HXCPP-NO-LEASE')
	@:killer('M-POSTLAND-HXCPP-IGNORES-GRANT')
	public function testTheHxcppBuildLeasesItsOwnShareAndCompilesOnItsGrant(): Void {
		final argv: Array<String> = PostLand.hxcppCommand('/tree', '/cache', Own('/p/scripts/wf-run', 10)).argv;
		Assert.equals('2-4', argv[argv.indexOf('--threads') + 1]);
		final bare: Array<String> = PostLand.hxcppCommand('/tree', '/cache', Unpooled).argv;
		Assert.equals('sh', bare[0]);
		Assert.stringContains('HXCPP_COMPILE_THREADS="$${WF_THREADS:-4}"', bare[2]);
	}

	@:pin('control')
	@:killer('M-POSTLAND-PHASE-MODE-ENVIRONMENT')
	public function testThePhasesOfASuiteRunLeaseFromThePoolWhateverLeaseTheirStarterHeld(): Void {
		final held: String = Sys.getEnv('WF_THREADS') ?? '';
		final root: String = Sys.getEnv('WF_PLUGIN_ROOT') ?? '';
		CliFixture.always(() -> {
			Sys.putEnv('WF_THREADS', held);
			Sys.putEnv('WF_PLUGIN_ROOT', root);
		}, () -> {
			Sys.putEnv('WF_THREADS', '3');
			Sys.putEnv('WF_PLUGIN_ROOT', '');
			Assert.isTrue(PostLand.phaseMode().match(Unpooled));
		});
	}

	@:pin('control')
	@:killer('M-POSTLAND-HXCPP-GRANT-FIELD')
	@:killer('M-POSTLAND-HXCPP-MARK-DRIFT')
	public function testTheHxcppGrantIsReadBackFromTheLineTheBuildCommandPrints(): Void {
		Assert.equals(3, PostLand.hxcppGrantOf('x\npost-land threads: 3\ny'));
		Assert.isNull(PostLand.hxcppGrantOf('post-land threads: \n'));
		// the first statement of the build's script is the echo of the grant: what it prints is what the regex reads
		final echo: String = PostLand.hxcppCommand('/tree', '/cache', Unpooled).argv[2].split(';')[0];
		Assert.equals(5, PostLand.hxcppGrantOf(Command.of(['sh', '-c', echo]).env('WF_THREADS', '5').run().out));
	}

	@:pin('control')
	@:killer('M-POSTLAND-PHASE-ROW-THREADS')
	public function testAPhaseLeavesItsOwnLedgerRowWithTheThreadsItHeld(): Void {
		TempDir.with(dir -> {
			Assert.isTrue(PostLand.timed(dir.path, 'lint', granted -> {
				granted(1);
				return Passed;
			}).match(Passed));
			final rows: Array<LedgerRow> = ExecLedger.under(dir.path).rows();
			Assert.equals(1, rows.length);
			Assert.equals('lint', rows[0].row);
			Assert.equals('post-land', rows[0].phase);
			Assert.equals(1, rows[0].threads);
		});
	}

	@:pin('control')
	@:killer('M-POSTLAND-LINT-UNBOUNDED-BY-DEFAULT')
	public function testTheWholeLintIsBoundedFromItsGrantAboveTheDriversDefaultForALeasedJob(): Void {
		final lint: Command = Command.of(['hxq', 'lint']);
		final tenMinutes: Int = 10 * 60 * 1000;
		Assert.isTrue(PostLand.lintLeased(Own('/p/scripts/wf-run', 10), lint, 'post-land-lint 0123abcd').limit() > tenMinutes);
		Assert.isTrue(PostLand.lintLeased(Unpooled, lint, 'post-land-lint 0123abcd').limit() > tenMinutes);
	}

	/** A detached run (`DetachedRow`) is one ledger row with the threads of the lease its caller granted. */
	@:pin('control')
	@:killer('M-DETACHED-ROW-THREADS')
	public function testADetachedRunRecordsTheThreadsItsLeaseGranted(): Void {
		final held: String = Sys.getEnv('WF_THREADS') ?? '';
		CliFixture.always(() -> Sys.putEnv('WF_THREADS', held), () -> {
			Sys.putEnv('WF_THREADS', '4');
			TempDir.with(dir -> {
				Assert.isTrue(DetachedRow.run(dir.path, dir.path, 'abc', 'arm-sweep', 'sweep', () -> Passed).match(Passed));
				final rows: Array<LedgerRow> = ExecLedger.under(dir.path).rows();
				Assert.equals(1, rows.length);
				Assert.equals('sweep', rows[0].row);
				Assert.equals('arm-sweep', rows[0].phase);
				Assert.equals(4, rows[0].threads);
				Assert.notNull(rows[0].at);
			});
		});
	}

	/** Where the platform meters processes, a detached run's row carries their cpu: a reading of zero, not no reading. */
	@:pin('control')
	@:killer('M-DETACHED-ROW-CPU')
	public function testADetachedRunRecordsTheCpuOfItsProcesses(): Void {
		if (Sys.systemName() != 'Mac') {
			Assert.pass('only macOS time(1) meters');
			return;
		}
		TempDir.with(dir -> {
			Assert.isTrue(DetachedRow.run(dir.path, dir.path, 'abc', 'arm-sweep', 'sweep', () -> Passed).match(Passed));
			Assert.notNull(ExecLedger.under(dir.path).rows()[0].cpuS);
		});
	}

}

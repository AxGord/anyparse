package unit.devkit;

import devkit.Branches;
import devkit.Command;
import devkit.Lease;
import devkit.Lease.LeaseMode;
import devkit.Pool;
import devkit.Result;
import devkit.Summary;
import devkit.TempDir;
import haxe.io.Path;
import utest.Assert;
import utest.Test;

using StringTools;
using Lambda;

/** `devkit.Branches`: a branch report survives its round trip, a lease is shared, and a branch that left no report fails its steps. */
@:nullSafety(Strict)
final class BranchesTest extends Test {

	public function testAReportRoundTripsEveryOutcome(): Void {
		final summary: Summary = new Summary();
		summary.add('a', Passed, 1, 'note');
		summary.add('b', Failed('why b'));
		summary.add('c', NotRun('why c'));
		summary.add('d', Skipped('why d'));
		final read: BranchReport = Branches.decode(Branches.encode('r1', summary.steps(), ['tests' => 3]));
		Assert.equals('r1', read.run);
		Assert.same(summary.steps(), read.steps);
		Assert.equals(3, read.readings['tests']);
	}

	@:pin('control')
	@:killer('M-BRANCHES-SHARE-WHOLE')
	public function testTheHeavyRowsShareWhatTheLeaseLeaves(): Void {
		Assert.equals(6, Branches.share(10, 4));
		Assert.equals(1, Branches.share(3, 5));
		Assert.isNull(Branches.share(null, 4));
	}

	@:pin('control')
	@:killer('M-BRANCHES-LIGHT-NONE')
	public function testEachBranchTakesItsOwnLeaseAndTheHeavyOneWhatTheOthersLeave(): Void {
		final branches: Array<Array<String>> = [['heavy', 'next'], ['lint'], ['short'], ['skipped']];
		final demand: Array<String> -> Null<Int> = rows -> {
			switch rows[0] {
				case 'heavy': null;
				case 'lint': 2;
				case 'short': 1;
				case _: 0;
			}
		};
		final command: Array<String> -> Command = rows -> Command.of(['node', 'dev.js', rows.join(',')]);
		final threadsOf: (LeaseMode, Array<String>) -> String = (mode, rows) -> {
			final argv: Array<String> = Branches.leased(mode, branches, demand, command, 'gate')(rows).argv;
			return argv[0] == 'node' ? 'none' : argv[argv.indexOf('--threads') + 1];
		};
		final pool: LeaseMode = Own('/p/scripts/wf-run', 10);
		Assert.equals(3, Branches.light(branches, demand));
		Assert.equals('2-7', threadsOf(pool, ['heavy', 'next']));
		Assert.equals('2', threadsOf(pool, ['lint']));
		Assert.equals('1', threadsOf(pool, ['short']));
		Assert.equals('none', threadsOf(pool, ['skipped']), 'a branch whose rows skip takes no lease');
		Assert.equals('1', threadsOf(Own('/p/scripts/wf-run', 4), ['heavy', 'next']), 'the heavy branch never takes less than one');
		Assert.equals('none', threadsOf(Held(10), ['heavy', 'next']), 'a held lease is split by the caller');
		Assert.equals('none', threadsOf(Unpooled, ['lint']));
	}

	@:pin('control')
	@:killer('M-BRANCHES-FOREIGN-REPORT')
	public function testAReportOfAnotherRunIsNone(): Void {
		TempDir.with(dir -> {
			final file: String = dir.file('a.json');
			sys.io.File.saveContent(file, Branches.encode('old', [], []));
			Assert.isNull(Branches.reportOf(file, 'new'));
			Assert.notNull(Branches.reportOf(file, 'old'));
			sys.io.File.saveContent(file, '{"steps": [], "readings": []}');
			Assert.isNull(Branches.reportOf(file, 'new'));
		});
	}

	public function testABranchWithoutAReportFailsItsSteps(): Void {
		TempDir.with(dir -> {
			final report: Array<String> -> String = names -> Path.join([dir.path, '${names[0]}.json']);
			final summary: Summary = new Summary();
			final left: String = Branches.encode('r1', [
				{
					name: 'a',
					outcome: Passed,
					ms: 0,
					note: ''
				}
			], ['n' => 1]);
			final readings: Map<String, Int> = Branches.run(
				'r1', [['a'], ['b']],
				['b', 'a'],
				names -> names[0] == 'a'
					? Command.of([
						'node',
						'-e',
						'require("fs").writeFileSync(process.argv[1], process.argv[2])',
						report(names),
						left
					])
					: Command.of(['node', '-e', 'process.exit(3)']),
				report, summary
			);
			Assert.equals(1, readings['n']);
			Assert.same(['b', 'a'], [for (step in summary.steps()) step.name]);
			Assert.isTrue(summary.steps()[0].outcome.match(NotRun(_)));
			Assert.isTrue(summary.steps()[1].outcome.match(Passed));
		});
	}

	/** A light branch queues a priority step ahead of the caller's own; the heavy one at the caller's own. */
	@:pin('control')
	@:killer('M-BRANCHES-LIGHT-NOT-AHEAD')
	public function testTheLightBranchesQueueAheadOfTheHeavyOne(): Void {
		final leased: Array<String> -> Command = Branches.leased(
			Own('/p/scripts/wf-run', 10), [['heavy'], ['light']],
			rows -> rows[0] == 'heavy' ? null : 2, rows -> Command.of(['node', rows[0]]), 'gate'
		);
		Assert.contains('--priority=${Lease.ahead()}', leased(['light']).argv);
		Assert.isFalse(leased(['heavy']).argv.exists(a -> a.startsWith('--priority')), 'the heavy one queues at the caller\'s own');
	}

	/**
	 * On a busy pool the heavy branch waits for its whole share with every free thread closed behind it: its light sibling,
	 * which fits in what is free, is granted at once, not once the pool drains. Runs the workflow engine's own `wf-run` over a
	 * pool of its own, the heavy branch arriving first; passes as skipped outside a workflow.
	 */
	public function testOnABusyPoolTheLightBranchIsNotHeldBehindTheHeavyOne(): Void {
		final root: String = Sys.getEnv('WF_PLUGIN_ROOT') ?? '';
		final wfRun: String = Path.join([root, 'scripts/wf-run']);
		if (root == '' || !sys.FileSystem.exists(wfRun)) {
			Assert.pass('no workflow engine to run a pool — skipped');
			return;
		}
		TempDir.with(dir -> {
			sys.io.File.saveContent(dir.file('config.json'), '{"budget": 6, "load_threshold": 1000}');
			final started: Float = Date.now().getTime();
			final elapsed: String = 'console.log(Date.now() - ${Std.string(started)})';
			final after: Float -> Command -> Command = (seconds, command) ->
				command.under(['sh', '-c', 'sleep $seconds; exec "$$@"', 'sh']);
			final leased: Array<String> -> Command = Branches.leased(
				Own(wfRun, 6), [['heavy'], ['light']],
				rows -> rows[0] == 'heavy' ? null : 2, rows -> Command.of(['node', '-e', elapsed]), 'busy'
			);
			final holder: Command = Command.of([wfRun, '--threads', '3', '--label', 'holder', '--', 'sleep', '4']);
			final runs: Array<Result> = Pool.of(3).run([
				holder.env('WF_POOL_DIR', dir.path),
				after(0.3, leased(['heavy'])).env('WF_POOL_DIR', dir.path),
				after(0.6, leased(['light'])).env('WF_POOL_DIR', dir.path)
			]);
			final light: Null<Int> = Std.parseInt(runs[2].out.trim());
			final heavy: Null<Int> = Std.parseInt(runs[1].out.trim());
			Assert.isTrue(
				light != null && light < 3000, 'the light branch ran while the holder still held its threads: ${runs[2].out}${runs[2].err}'
			);
			Assert.isTrue(heavy != null && heavy >= 3000, 'the heavy one waited for its whole share: ${runs[1].out}${runs[1].err}');
		});
	}

}

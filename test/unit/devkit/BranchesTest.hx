package unit.devkit;

import devkit.Branches;
import devkit.Command;
import devkit.Lease;
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

	public function testAnExcerptSurvivesTheRoundTripAndAnOlderReportHasNone(): Void {
		final summary: Summary = new Summary();
		summary.add('lint', Failed('1 new'), 1, '', ['+ a.hx  r  new']);
		final read: BranchReport = Branches.decode(Branches.encode('r1', summary.steps(), []));
		Assert.same(['+ a.hx  r  new'], read.steps[0].excerpt);
		final older: BranchReport = Branches.decode(
			'{"run": "r0", "steps": [{"name": "a", "outcome": "failed", "why": "w", "ms": 1, "note": ""}], "readings": []}'
		);
		Assert.same([], older.steps[0].excerpt);
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
					note: '',
					excerpt: []
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
					: Command.of(['node', '-e', 'console.error("boom: it broke"); process.exitCode = 3']),
				report, summary
			);
			Assert.equals(1, readings['n']);
			Assert.stringContains('b:\n  boom: it broke', summary.excerpts(), 'the dead branch\'s own last words stand in for its report');
			Assert.same(['b', 'a'], [for (step in summary.steps()) step.name]);
			Assert.isTrue(summary.steps()[0].outcome.match(NotRun(_)));
			Assert.isTrue(summary.steps()[1].outcome.match(Passed));
		});
	}

	/**
	 * A branch cut for silence under a lease wrapper names the row it stood in: the wrapper's own stderr line and its long path
	 * must not stand in for how the process failed.
	 */
	public function testACutBranchNamesItsRowBehindAWrappersLongPath(): Void {
		TempDir.with(dir -> {
			final wrapperDir: String = dir.file('a-directory-whose-name-is-long-enough-to-push-the-row-past-the-reason-width-of-a-step');
			sys.FileSystem.createDirectory(wrapperDir);
			final wrapper: String = Path.join([wrapperDir, 'wf-run']);
			final script: Array<String> = [
				'#!/bin/sh',
				'echo "wf-run: waiting for 1 threads - held 6/10 by slice-gate SOME-SLICE kits (2), slice-gate OTHER lint (1)" >&2',
				'printf lint > "$$1"',
				'exec node -e "setInterval(() => {}, 1000)"',
				''
			];
			sys.io.File.saveContent(wrapper, script.join('\n'));
			js.Syntax.code("require('fs').chmodSync({0}, 0o755)", wrapper);
			final progress: String = dir.file('lint.json.progress');
			final summary: Summary = new Summary();
			final readings: Map<String, Int> = Branches.run(
				'r1', [['lint']],
				['lint'], names -> Command.of([wrapper, progress]).watched(1000, progress, true), names -> dir.file('lint.json'), summary
			);
			Assert.isFalse(readings.keys().hasNext(), 'a cut branch read nothing');
			final outcome: Outcome = summary.steps()[0].outcome;
			switch outcome {
				case NotRun(why):
					Assert.stringContains('last started: lint', why);
					Assert.isTrue(why.length < 300, why);
				case _:
					Assert.fail('$outcome');
			}
		});
	}

	/** A branch that began after its pool lease shows the seconds on its first row and in the total; an immediate grant shows none. */
	public function testALeaseWaitIsShownOnTheRowAndInTheTotalButAnImmediateGrantIsNot(): Void {
		TempDir.with(dir -> {
			final steps: Array<Step> = [
				{
					name: 'a',
					outcome: Passed,
					ms: 0,
					note: '',
					excerpt: []
				}
			];
			final now: Float = Date.now().getTime();
			final run: (Float) -> Summary = began -> {
				final report: String = dir.file('${Std.int(began - now)}.json');
				final left: String = Branches.encode('r1', steps, [], began);
				final script: String = 'require("fs").writeFileSync(process.argv[1], process.argv[2])';
				final summary: Summary = new Summary();
				final readings: Map<String, Int> = Branches.run(
					'r1', [['a']], ['a'], names -> Command.of(['node', '-e', script, report, left]), names -> report, summary
				);
				Assert.isFalse(readings.keys().hasNext());
				summary;
			};
			final delayed: Summary = run(now + 2400);
			Assert.stringContains('waited 2s', delayed.table());
			Assert.equals('waited 2s', delayed.waitedTotal());
			final immediate: Summary = run(now);
			Assert.isFalse(immediate.table().contains('waited'), immediate.table());
			Assert.equals('', immediate.waitedTotal());
		});
	}

	/** Two branches that wait at once cost the run the longer wait, never the sum of both. */
	public function testConcurrentBranchesTotalTheirLongestWait(): Void {
		TempDir.with(dir -> {
			final now: Float = Date.now().getTime();
			final script: String = 'require("fs").writeFileSync(process.argv[1], process.argv[2])';
			final report: String -> String = name -> dir.file('$name.json');
			final left: String -> String = name -> Branches.encode('r1', [
				{
					name: name,
					outcome: Passed,
					ms: 0,
					note: '',
					excerpt: []
				}
			], [], now + 2400);
			final summary: Summary = new Summary();
			final readings: Map<String, Int> = Branches.run(
				'r1', [['a'], ['b']],
				['a', 'b'],
				names -> Command.of(['node', '-e', script, report(names[0]), left(names[0])]), names -> report(names[0]), summary
			);
			Assert.isFalse(readings.keys().hasNext());
			Assert.stringContains('waited 2s', summary.table());
			Assert.equals('waited 2s', summary.waitedTotal());
		});
	}

	/** The stamp a branch leaves is its process start: not after now, and no earlier than the process's uptime reaches. */
	public function testLeaveStampsTheProcessStart(): Void {
		TempDir.with(dir -> {
			final file: String = dir.file('r.json');
			final earliest: Float = Date.now().getTime() - js.Node.process.uptime() * 1000 - 1000;
			Branches.leave(file, 'r1', new Summary(), []);
			final started: Null<Float> = Branches.decode(sys.io.File.getContent(file)).started;
			Assert.notNull(started);
			if (started != null) {
				Assert.isTrue(started >= earliest, 'start $started before $earliest');
				final latest: Float = Date.now().getTime() - js.Node.process.uptime() * 1000 + 250;
				Assert.isTrue(started <= latest, 'start $started is the leave time, not the process start');
			}
		});
	}

	/** A report names when its branch began, and an older report names none. */
	public function testAReportKeepsWhenItsBranchBegan(): Void {
		Assert.equals(5.0, Branches.decode(Branches.encode('r1', [], [], 5)).started);
		Assert.isNull(Branches.decode('{"run": "r0", "steps": [], "readings": []}').started);
		Assert.equals(0.0, Branches.waitedMs(10, 4));
	}

	/** A branch cut in its second row keeps the result of its first: the report it left names only that row, which stays passed. */
	public function testACutBranchKeepsTheRowsItFinished(): Void {
		TempDir.with(dir -> {
			final report: String = dir.file('a.json');
			final progress: String = '$report.progress';
			final left: String = Branches.encode('r1', [
				{
					name: 'a',
					outcome: Passed,
					ms: 0,
					note: '',
					excerpt: []
				}
			], []);
			final script: String = 'const fs = require("fs"); fs.writeFileSync(process.argv[1], process.argv[2]); '
				+ 'fs.writeFileSync(process.argv[3], "b"); setInterval(() => {}, 1000)';
			final summary: Summary = new Summary();
			final readings: Map<String, Int> = Branches.run(
				'r1', [['a', 'b']],
				['a', 'b'],
				names -> Command.of(['node', '-e', script, report, left, progress]).watched(1000, progress, true), names -> report, summary
			);
			Assert.isFalse(readings.keys().hasNext());
			Assert.same(['a', 'b'], [for (step in summary.steps()) step.name]);
			Assert.isTrue(summary.steps()[0].outcome.match(Passed), 'the finished row keeps its result');
			switch summary.steps()[1].outcome {
				case NotRun(why):
					Assert.stringContains('last started: b', why);
				case other:
					Assert.fail('$other');
			}
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
			final elapsed: String = 'console.log(Date.now() - ${started})';
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

	/** Two heavy branches split what the budget leaves beside the light ones, each at least one thread; one heavy branch takes it whole. */
	@:pin('control')
	@:killer('M-BRANCHES-HEAVY-NOT-SPLIT')
	public function testTwoHeavyBranchesSplitWhatTheLightOnesLeave(): Void {
		final demand: Array<String> -> Null<Int> = rows -> rows[0] == 'lint' ? 2 : null;
		final two: Array<Array<String>> = [['suite'], ['base'], ['lint']];
		Assert.equals(4, Branches.perHeavy(10, two, demand));
		Assert.equals(1, Branches.perHeavy(3, two, demand));
		Assert.isNull(Branches.perHeavy(null, two, demand));
		Assert.equals(8, Branches.perHeavy(10, [['suite'], ['lint']], demand));
		final pool: LeaseMode = Own('/p/scripts/wf-run', 10);
		final argv: Array<String> = Branches.leased(pool, two, demand, rows -> Command.of(['node', rows[0]]), 'gate')(['base']).argv;
		Assert.equals('2-4', argv[argv.indexOf('--threads') + 1], 'the base branch asks for its half, not the whole rest');
	}

}

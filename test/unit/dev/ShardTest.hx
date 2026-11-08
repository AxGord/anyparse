package unit.dev;

import anyparse.query.ShardPlan;
import anyparse.util.Compare;
import dev.Shard;
import devkit.Args.UsageError;
import devkit.Cmd.cmd;
import devkit.Result;
import devkit.TempDir;
import sys.FileSystem;
import sys.io.File;
import testkit.TestRegistry;
import utest.Assert;
import utest.Test;

using Lambda;
using StringTools;

/**
 * `dev shard` end to end over a FAKE runner: a node script that lists the real registry, then answers each shard's
 * `APQ_TEST` with a transcript of one test per class — green, red on the shard holding the first class, or dying there
 * mid-run. What is pinned is the contract the battery reads: the aggregate line, the one verdict line, and that a red
 * or unfinished shard can never end on `PASS`.
 */
@:nullSafety(Strict)
final class ShardTest extends Test {

	/**
	 * The fake runner. It counts a class once however it is sliced (only slice `0/k` counts), so a monolith run of it and
	 * any shard split of it agree; `mode` beside it picks how the shard holding the first class ends, and `runs` gets a
	 * `shard` or `mono` line per run it is started for (a monolith run has an empty `APQ_TEST`). It sets its exit
	 * status instead of calling `process.exit`, which would cut off output still queued for a pipe.
	 */
	private static inline final RUNNER: String = "const fs = require('fs'), path = require('path');
const classes = fs.readFileSync(path.join(__dirname, 'classes.txt'), 'utf8').split('\\n').filter(c => c);
(function () {
if (process.argv.includes('--list-classes')) return process.stdout.write(classes.join('\\n') + '\\n');
fs.appendFileSync(path.join(__dirname, 'runs'), (process.env.APQ_TEST ? 'shard' : 'mono') + '\\n');
const mode = fs.readFileSync(path.join(__dirname, 'mode'), 'utf8').trim();
const tokens = (process.env.APQ_TEST || '').split(',').filter(t => t);
const run = tokens.length === 0 ? classes : tokens;
const counted = run.filter(t => !t.includes('#') || t.split('#')[1].startsWith('0/'));
const hit = run.some(t => t.split('#')[0] === classes[0]);
if (mode === 'orphan') {
  const c = require('child_process').spawn(process.execPath, ['-e', 'setTimeout(() => {}, 15000)'], { stdio: 'ignore' });
  c.unref(); fs.writeFileSync(path.join(__dirname, 'orphan.pid'), String(c.pid));
}
if (mode === 'stall' && hit) {
  fs.writeFileSync(process.env.APQ_TEST_PROGRESS, 'unit.Fake.testStuck');
  return setInterval(() => {}, 1000);
}
if (hit && mode === 'die') { process.exitCode = 1; return process.stdout.write('  testA: OK .\\n'); }
if (process.env.APQ_TEST_TIMING) fs.writeFileSync(process.env.APQ_TEST_TIMING, run.map(t => '3\\t1\\t' + t.split('#')[0] + '\\n').join(''));
const failed = hit && mode === 'red' ? 1 : 0;
const n = counted.length;
process.stdout.write((failed ? classes[0] + '\\n  testBroken: FAIL\\n    line: 1, nope\\n' : '') + 'tests executed: ' + n + '\\nassertations: ' + 2 * n
  + '\\nsuccesses: ' + (2 * n - failed) + '\\nerrors: 0\\nfailures: ' + failed + '\\nwarnings: 0\\nresults: (success: ' + (failed === 0) + ')\\n');
process.exitCode = failed;
})();
";

	public function testExpectIsTwoCountsAndOneSlash(): Void {
		Assert.same({ tests: 12, assertions: 34 }, Shard.parseExpect('12/34'));
		for (bad in ['12', '1/2/3', 'a/1', '/1', '1/', '-1/2']) Assert.raises(() -> Shard.parseExpect(bad), UsageError, bad);
	}

	public function testTheFileCountTakesTestFilesInAPackageOnly(): Void {
		TempDir.with(dir -> {
			Assert.isNull(Shard.testFileCount(dir.file('test')), 'no test tree');
			FileSystem.createDirectory(dir.file('test/unit/deep'));
			for (file in [
				'RootTest.hx',
				'unit/ATest.hx',
				'unit/deep/BTest.hx',
				'unit/Helper.hx',
				'unit/ATestBase.hx',
				'unit/notes.txt'
			]) File.saveContent(dir.file('test/$file'), '');
			Assert.equals(2, Shard.testFileCount(dir.file('test')), 'a root-level file is an entry point, a helper is no test');
		});
	}

	public function testTimingsSumEachClassSlowestFirstThenByName(): Void {
		Assert.equals('9\t3\tb.B\n4\t1\ta.A\n4\t2\tc.C\n', Shard.mergeTimings('4\t2\tc.C\n5\t2\tb.B\nnoise\n4\t1\ta.A\n4\t1\tb.B\n\n'));
	}

	public function testAGreenRunVerifiedAgainstTheMonolithPasses(): Void {
		TempDir.with(dir -> {
			final run: Ran = runFake(dir, 'green', 3, true);
			Assert.equals(0, run.status, run.warned.join('\n'));
			final classes: Int = TestRegistry.classNames().length;
			Assert.isTrue(
				~/^--- suite-shard: \d+ classes \/ \d+ tests \/ \d+ assertions \/ 0 failures \/ 0 errors in \d+\.\d{3}s across 3 shards ---$/.match(
					run.printed.find(l -> l.startsWith('--- ')) ?? ''
				),
				run.printed.join('\n')
			);
			Assert.equals(
				'parity: counts verified against a monolith run ($classes tests / ${2 * classes} assertions)',
				run.printed[run.printed.length - 2]
			);
			Assert.equals(
				'suite-shard: PASS — $classes classes / $classes tests / ${2 * classes} assertions over 3 shards',
				run.printed[run.printed.length - 1]
			);
			Assert.isTrue(FileSystem.exists(dir.file('bin/.suite-timings.tsv')), 'a green run refreshes the weights');
			Assert.equals(File.getContent(dir.file('bin/.suite-timings.tsv')), File.getContent(dir.file('timings.tsv')));
		});
	}

	/** One shard under `--verify` is the one-process run already: node starts once, and the parity note says so. */
	public function testOneShardUnderVerifyStartsNodeOnce(): Void {
		TempDir.with(dir -> {
			final run: Ran = runFake(dir, 'green', 1, true);
			Assert.equals(0, run.status, run.warned.join('\n'));
			final classes: Int = TestRegistry.classNames().length;
			Assert.same(['shard'], runsOf(dir));
			Assert.equals(
				'parity: the one shard is the monolith run (all $classes classes whole, in registry order); no second run',
				run.printed[run.printed.length - 2]
			);
			Assert.equals(
				'suite-shard: PASS — $classes classes / $classes tests / ${2 * classes} assertions over 1 shards',
				run.printed[run.printed.length - 1]
			);
		});
	}

	/** A red one shard is red under `--verify` too: taking the shard for the monolith never turns its verdict green. */
	public function testARedOneShardUnderVerifyStaysRed(): Void {
		TempDir.with(dir -> {
			final run: Ran = runFake(dir, 'red', 1, true);
			Assert.equals(1, run.status);
			Assert.same(['shard'], runsOf(dir));
			Assert.stringContains('suite-shard: FAILED', run.printed[run.printed.length - 1]);
		});
	}

	/** Two shards under `--verify` still run the monolith after them: the class order differs between processes. */
	public function testTwoShardsUnderVerifyStillRunTheMonolith(): Void {
		TempDir.with(dir -> {
			final run: Ran = runFake(dir, 'green', 2, true);
			Assert.equals(0, run.status, run.warned.join('\n'));
			Assert.same(['mono', 'shard', 'shard'], runsOf(dir));
			Assert.stringContains('counts verified against a monolith run', run.printed[run.printed.length - 2]);
		});
	}

	public function testARedShardFailsTheRunAndNamesItsFirstFailure(): Void {
		TempDir.with(dir -> {
			final run: Ran = runFake(dir, 'red', 3, false);
			Assert.equals(1, run.status);
			final verdict: String = run.printed[run.printed.length - 1];
			Assert.isTrue(~/^suite-shard: FAILED — shard \d is red \(1 failures \/ 0 errors\)$/.match(verdict), verdict);
			Assert.isTrue(run.printed.exists(l -> ~/^  shard \d first failure: .*testBroken/.match(l)), run.printed.join('\n'));
			Assert.isFalse(FileSystem.exists(dir.file('bin/.suite-timings.tsv')), 'a red run leaves the weights alone');
		});
	}

	public function testAShardThatDiedIsPartialNeverGreen(): Void {
		TempDir.with(dir -> {
			final run: Ran = runFake(dir, 'die', 3, false);
			Assert.equals(1, run.status);
			Assert.stringContains('it did not finish', run.printed[run.printed.length - 1]);
			Assert.isTrue(
				run.printed.exists(l -> l.endsWith('(exit 1) in 0.0s  <-- did NOT finish: these counts are partial')),
				run.printed.join('\n')
			);
			Assert.isTrue(run.warned.exists(l -> l.contains('SUM OF WHAT RAN')), run.warned.join('\n'));
		});
	}

	public function testAProducerThatDisagreesWithTheTestFilesIsRefusedBeforeAnyShardRuns(): Void {
		TempDir.with(dir -> {
			FileSystem.createDirectory(dir.file('test/unit'));
			File.saveContent(dir.file('test/unit/OnlyOneTest.hx'), '');
			final run: Ran = runFake(dir, 'green', 2, false);
			Assert.equals(1, run.status);
			Assert.isTrue(run.warned.exists(l -> l.contains('the test tree holds 1 *Test.hx files.')), run.warned.join('\n'));
			Assert.equals(0, run.printed.length, 'no shard ran, so nothing was measured');
		});
	}

	@:pin('control')
	@:killer('M-SHARD-SUBSET-REFRESHES-WEIGHTS')
	public function testASubsetRunsOnlyItsClassesOverNoMoreShardsThanItHasAndLeavesTheWeights(): Void {
		TempDir.with(dir -> {
			FileSystem.createDirectory(dir.file('test/unit'));
			File.saveContent(dir.file('test/unit/OnlyOneTest.hx'), '');
			final names: Array<String> = TestRegistry.classNames().filter(n -> !ShardPlan.STICKY_CLASSES.contains(n)).slice(0, 2);
			final run: Ran = runFake(dir, 'green', 3, true, null, null, names.concat(['unit.NoSuchTest']));
			Assert.equals(0, run.status, run.warned.join('\n'));
			Assert.equals('suite-shard: PASS — 2 classes / 2 tests / 4 assertions over 2 shards', run.printed[run.printed.length - 1]);
			Assert.isTrue(run.printed.exists(l -> l.contains('a subset of ')), run.printed.join('\n'));
			Assert.isFalse(
				FileSystem.exists(dir.file('bin/.suite-timings.tsv')), 'a subset never rewrites the weights a whole run deals by'
			);
		});
	}

	public function testAnExpectThatDisagreesFailsTheRun(): Void {
		TempDir.with(dir -> {
			final run: Ran = runFake(dir, 'green', 2, false, { tests: 1, assertions: 2 });
			Assert.equals(1, run.status);
			Assert.stringContains('count parity FAILED — shards ', run.printed[run.printed.length - 1]);
			Assert.equals('parity: counts DIVERGED from --expect 1/2', run.printed[run.printed.length - 2]);
		});
	}

	/** A runner given `APQ_TEST_PROGRESS` leaves the test it started last in that file: the watchdog's sign of life. */
	public function testTheRunnerLeavesTheTestItStartedLast(): Void {
		TempDir.with(dir -> {
			final progress: String = dir.file('progress');
			final run: Result = cmd('${js.Node.process.execPath} ${js.Node.process.argv[1]}')
				.env('APQ_TEST', 'unit.devkit.TallyTest')
				.env('APQ_TEST_PROGRESS', progress)
				.run();
			Assert.equals(0, run.status, run.out + run.err);
			Assert.isTrue(File.getContent(progress).startsWith('unit.devkit.TallyTest.test'), File.getContent(progress));
		});
	}

	/** What a shard's process group left running is named in the run's warnings and killed. */
	public function testAnOrphanAShardLeftIsWarnedAbout(): Void {
		TempDir.with(dir -> {
			final run: Ran = runFake(dir, 'orphan', 1, false);
			final pid: String = File.getContent(dir.file('orphan.pid'));
			killQuietly(Std.parseInt(pid));
			Assert.equals(0, run.status, run.printed.join('\n'));
			Assert.isTrue(run.warned.exists(l -> l.startsWith('dev shard: shard 0: orphan left running: $pid ')), run.warned.join('\n'));
		});
	}

	/** A shard cut for making no progress fails the run, and the verdict says why and where it stood. */
	public function testAShardCutForSilenceFailsTheRunWithItsReason(): Void {
		TempDir.with(dir -> {
			final run: Ran = runFake(dir, 'stall', 1, false, null, 2000);
			Assert.equals(1, run.status);
			final verdict: String = run.printed[run.printed.length - 1];
			Assert.stringContains('suite-shard: FAILED', verdict);
			Assert.stringContains('shard 0: ', verdict);
			Assert.stringContains('made no progress for 2 s', verdict);
			Assert.stringContains('last started: unit.Fake.testStuck', verdict);
		});
	}

	/** A red run hands the job the failing tests as `Class.method`, a green one an empty list. */
	@:pin('control')
	@:killer('M-SHARD-FAILING-NOT-COLLECTED')
	@:killer('M-SHARD-FAILING-NOT-HANDED')
	public function testARedRunHandsItsFailingTestsToTheJob(): Void {
		final handed: Array<Array<String>> = [];
		TempDir.with(dir -> runFake(dir, 'red', 2, false, null, null, null, names -> handed.push(names)));
		Assert.same([['${TestRegistry.classNames()[0]}.testBroken']], handed);
		handed.resize(0);
		TempDir.with(dir -> runFake(dir, 'green', 2, false, null, null, null, names -> handed.push(names)));
		Assert.same([[]], handed);
	}

	/** `dev shard` over the fake runner in `dir` in `mode`; a kept work directory is removed again. */
	private static function runFake(
		dir: TempDir, mode: String, shards: Int, verify: Bool, ?expect: SuiteCounts, ?idleMs: Int, ?only: Array<String>,
		?failing: Array<String> -> Void
	): Ran {
		File.saveContent(dir.file('fake.js'), RUNNER);
		File.saveContent(dir.file('classes.txt'), TestRegistry.classNames().join('\n') + '\n');
		File.saveContent(dir.file('mode'), mode);
		FileSystem.createDirectory(dir.file('bin'));
		final printed: Array<String> = [];
		final warned: Array<String> = [];
		final status: Int = Shard.run({
			repo: dir.path,
			testJs: dir.file('fake.js'),
			shards: shards,
			verify: verify,
			expect: expect,
			planOnly: false,
			keep: false,
			timings: dir.file('timings.tsv'),
			fixtureCache: null,
			print: printed.push,
			warn: warned.push,
			idleMs: idleMs,
			failing: failing,
			only: only
		});
		for (line in warned) if (line.startsWith('dev shard: work files kept in '))
			js.Syntax.code(
				"require('fs').rmSync({0}, { recursive: true, force: true })", line.substr('dev shard: work files kept in '.length)
			);
		return { status: status, printed: printed, warned: warned };
	}

	/** The runs the fake runner was started for, sorted: `mono` or `shard` each. */
	private static function runsOf(dir: TempDir): Array<String> {
		final lines: Array<String> = File.getContent(dir.file('runs')).split('\n').filter(l -> l != '');
		lines.sort(Compare.compareString);
		return lines;
	}

	private static function killQuietly(pid: Null<Int>): Void {
		if (pid != null) try js.Node.process.kill(pid) catch (exception: haxe.Exception) { // noqa: swallowed-exception
			// the sleeper may be gone already
		}
	}

}

/** What one fake `dev shard` run returned and said. */
private typedef Ran = {
	var status: Int;
	var printed: Array<String>;
	var warned: Array<String>;
}

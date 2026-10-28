package unit.dev;

import dev.Shard;
import devkit.Args.UsageError;
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
	 * any shard split of it agree; `mode` beside it picks how the shard holding the first class ends. It sets its exit
	 * status instead of calling `process.exit`, which would cut off output still queued for a pipe.
	 */
	private static inline final RUNNER: String = "const fs = require('fs'), path = require('path');
const classes = fs.readFileSync(path.join(__dirname, 'classes.txt'), 'utf8').split('\\n').filter(c => c);
(function () {
if (process.argv.includes('--list-classes')) return process.stdout.write(classes.join('\\n') + '\\n');
const mode = fs.readFileSync(path.join(__dirname, 'mode'), 'utf8').trim();
const tokens = (process.env.APQ_TEST || '').split(',').filter(t => t);
const run = tokens.length === 0 ? classes : tokens;
const counted = run.filter(t => !t.includes('#') || t.split('#')[1].startsWith('0/'));
const hit = run.some(t => t.split('#')[0] === classes[0]);
if (hit && mode === 'die') { process.exitCode = 1; return process.stdout.write('  testA: OK .\\n'); }
if (process.env.APQ_TEST_TIMING) fs.writeFileSync(process.env.APQ_TEST_TIMING, run.map(t => '3\\t1\\t' + t.split('#')[0] + '\\n').join(''));
const failed = hit && mode === 'red' ? 1 : 0;
const n = counted.length;
process.stdout.write((failed ? classes[0] + '\\n  testBroken: FAIL: nope\\n' : '') + 'tests executed: ' + n + '\\nassertations: ' + 2 * n
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

	public function testAnExpectThatDisagreesFailsTheRun(): Void {
		TempDir.with(dir -> {
			final run: Ran = runFake(dir, 'green', 2, false, { tests: 1, assertions: 2 });
			Assert.equals(1, run.status);
			Assert.stringContains('count parity FAILED — shards ', run.printed[run.printed.length - 1]);
			Assert.equals('parity: counts DIVERGED from --expect 1/2', run.printed[run.printed.length - 2]);
		});
	}

	/** `dev shard` over the fake runner in `dir` in `mode`; a kept work directory is removed again. */
	private static function runFake(dir: TempDir, mode: String, shards: Int, verify: Bool, ?expect: SuiteCounts): Ran {
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
			warn: warned.push
		});
		for (line in warned) if (line.startsWith('dev shard: work files kept in '))
			js.Syntax.code(
				"require('fs').rmSync({0}, { recursive: true, force: true })", line.substr('dev shard: work files kept in '.length)
			);
		return { status: status, printed: printed, warned: warned };
	}

}

/** What one fake `dev shard` run returned and said. */
private typedef Ran = {
	var status: Int;
	var printed: Array<String>;
	var warned: Array<String>;
}

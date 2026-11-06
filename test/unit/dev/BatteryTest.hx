package unit.dev;

import anyparse.grammar.json.JsonFormat;
import dev.Battery;
import dev.BatteryPlan;
import dev.BatteryPlanWriter;
import devkit.Args.UsageError;
import devkit.BranchReportJson;
import devkit.BranchReportJsonParser;
import devkit.Cmd.cmd;
import devkit.Result;
import devkit.StepRecord;
import devkit.Summary.Outcome;
import devkit.TempDir;
import js.node.Fs.Fs;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `dev battery`'s readings: which snapshot a run compares against, the counts it reads off the suite and the sweep, the
 * corpus gate, the cross-config one-pass set and the lines that close a run. The steps themselves run the project's own
 * tools, and the parity with the script it replaced is a reading of one tree, not a test.
 */
@:nullSafety(Strict)
final class BatteryTest extends Test {

	/**
	 * A `bin/test.js` that lists the two classes the shard plan pins and answers every run with a green utest report, so the suite
	 * step passes and the corpus class — which would write the sweep snapshot — never runs.
	 */
	private static final GREEN_RUNNER: String = "const a=process.argv.slice(2);if(a.includes('--list-classes'))"
		+ "console.log('unit.grammar.haxe.HxFormatterCorpusTest\\nunit.cli.ApqDxTier5CliTest');else console.log('tests executed: 1\\n"
		+ "assertations: 1\\nsuccesses: 1\\nerrors: 0\\nfailures: 0\\nwarnings: 0\\n\\nresults: ALL TESTS OK (success: true)');";

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

	public function testTheDefaultBaseIsTheFirstParentWhateverElseTheCacheHolds(): Void {
		TempDir.with(dir -> {
			final repo: String = dir.file('repo');
			FileSystem.createDirectory(repo);
			git(repo, ['init', '-q', '-b', 'main']);
			Assert.isNull(Battery.defaultBase(repo), 'no commit yet');
			for (name in ['first', 'second']) {
				File.saveContent('$repo/$name.txt', name);
				git(repo, ['add', '.']);
				git(repo, ['commit', '-q', '-m', name]);
			}
			final parent: String = cmd('git -C $repo rev-parse --short=${Battery.KEY_LENGTH} HEAD~1').run().out.trim();
			final head: String = cmd('git -C $repo rev-parse --short=${Battery.KEY_LENGTH} HEAD').run().out.trim();
			// a snapshot of another tree, written after the parent's, is the one an mtime pick would take
			for (key in [parent, 'ffff0000', head]) File.saveContent(dir.file('$key-suite.txt'), '1 2\n');
			Fs.utimesSync(dir.file('$parent-suite.txt'), Date.fromTime(1000000), Date.fromTime(1000000));
			Fs.utimesSync(dir.file('ffff0000-suite.txt'), Date.fromTime(3000000), Date.fromTime(3000000));
			Assert.equals(parent, Battery.defaultBase(repo));
			Assert.equals(parent, Battery.baseOf(null, false, repo));
			Assert.equals('named', Battery.baseOf('named', false, repo), '--base wins');
			Assert.isNull(Battery.baseOf(null, true, repo), '--no-base compares nothing');
			Assert.raises(() -> Battery.baseOf('named', true, repo), UsageError);
		});
	}

	public function testARedBatteryStillKeepsEveryReadingItProduced(): Void {
		TempDir.with(dir -> {
			final work: String = dir.file('work');
			FileSystem.createDirectory(work);
			File.saveContent('$work/lint-anyparse.json', '{}');
			File.saveContent(dir.file('abc-suite.txt'), 'stale');
			File.saveContent(dir.file('abc-sweep.json'), 'stale');
			final saved: Array<String> = [];
			// the suite was red: its counts were read, the corpus never ran
			final readings: Map<String, Int> = ['tests' => 12, 'assertions' => 34, 'lint-anyparse' => 1];
			Assert.isNull(Battery.keepSnapshot(dir.path, 'abc', work, readings, file -> {
				saved.push(file);
				return new Result('sweep', {
					status: 0,
					out: '',
					err: '',
					failure: '',
					overflowed: false
				});
			}));
			Assert.equals('12 34', File.getContent(dir.file('abc-suite.txt')).trim());
			Assert.isTrue(FileSystem.exists(dir.file('abc-anyparse.json')));
			Assert.same([], saved, 'a sweep nobody read is not saved');
			Assert.equals('stale', File.getContent(dir.file('abc-sweep.json')), 'a row that read nothing keeps the earlier file');
		});
	}

	@:pin('control')
	@:killer('M-BATTERY-SNAPSHOT-KEPT')
	public function testTheSuiteRunsOverNoSnapshotOfAPreviousRun(): Void {
		TempDir.with(dir -> {
			final tree: String = dir.file('tree');
			final work: String = dir.file('work');
			FileSystem.createDirectory(dir.file('tree/bin'));
			FileSystem.createDirectory(work);
			File.saveContent(dir.file('tree/bin/test.js'), GREEN_RUNNER);
			final engine: String = Sys.getEnv('HXQ_BIN') ?? FileSystem.fullPath('bin/apq.js');
			File.saveContent(dir.file('tree/bin/hxq'), 'cmd="$$1"; shift; exec node "$engine" "$$cmd" --lang haxe "$$@"\n');
			File.saveContent(dir.file('tree/bin/.last-sweep.json'), '{"stale":1}');
			final plan: BatteryPlan = {
				repo: tree,
				work: work,
				cache: dir.file('cache'),
				head: 'h1',
				base: null,
				baseSuite: null,
				shards: 1,
				quick: true,
				snapshot: false,
				allowBlast: false,
				allow: [],
				client: null,
				jvmSkip: '--no-jvm',
				run: 'r',
				ownLease: false
			};
			File.saveContent(dir.file('work/plan.json'), BatteryPlanWriter.write(plan, JsonFormat.instance.compactWriteOptions));
			Assert.equals(0, Battery.main(['--rows', 'suite,corpus', '--plan', dir.file('work/plan.json')]));
			Assert.isFalse(FileSystem.exists(dir.file('tree/bin/.last-sweep.json')), 'the previous run\'s sweep is not there to be read');
			Assert.equals(
				'{"stale":1}', File.getContent(dir.file('tree/bin/.prev-sweep.json')), 'it is moved to where the corpus class rotates it'
			);
			final steps: Array<StepRecord> = BranchReportJsonParser.parse(File.getContent(dir.file('work/branch-suite.json'))).steps;
			Assert.same(
				[{ name: 'suite', outcome: 'passed' }, { name: 'corpus', outcome: 'failed' }],
				steps.map(s -> {name: s.name, outcome: s.outcome })
			);
		});
	}

	public function testARunThatReadNothingKeepsNoSnapshot(): Void {
		TempDir.with(dir -> {
			Assert.isNull(Battery.keepSnapshot(dir.path, 'abc', dir.file('work'), [], file -> throw 'no sweep to save'));
			Assert.isFalse(FileSystem.exists(dir.file('abc-suite.txt')), 'the file that says a snapshot exists is not written');
		});
	}

	public function testARunSaysWhenItsBaseHasNoSnapshotToCompareWith(): Void {
		TempDir.with(dir -> {
			Assert.stringContains('no cached baseline', Battery.startLine('/r', 'h1', null, dir.path));
			Assert.stringContains('has no snapshot — nothing compared', Battery.startLine('/r', 'h1', 'b1', dir.path));
			File.saveContent(dir.file('b1-suite.txt'), '1 2\n');
			Assert.stringContains('comparing against b1', Battery.startLine('/r', 'h1', 'b1', dir.path));
		});
	}

	public function testALintThatProducedNothingKeepsNoLintSnapshot(): Void {
		TempDir.with(dir -> {
			final work: String = dir.file('work');
			FileSystem.createDirectory(work);
			File.saveContent('$work/lint-anyparse.json', '');
			File.saveContent('$work/lint-client.json', 'garbage');
			File.saveContent(dir.file('abc-anyparse.json'), '{"kept":1}');
			final readings: Map<String, Int> = ['tests' => 1, 'assertions' => 2];
			Assert.isNull(Battery.keepSnapshot(dir.path, 'abc', work, readings, file -> throw 'no sweep to save'));
			Assert.equals('{"kept":1}', File.getContent(dir.file('abc-anyparse.json')), 'an unread lint does not replace the kept one');
			Assert.isFalse(FileSystem.exists(dir.file('abc-client.json')));
		});
	}

	@:pin('control')
	@:killer('M-BATTERY-REUSED-SWEEP-IGNORED')
	public function testASuiteTheGateStandsForIsItsReadingAndTheCorpusJudgesTheGatesSnapshot(): Void {
		TempDir.with(dir -> {
			final tree: String = dir.file('tree');
			final work: String = dir.file('work');
			FileSystem.createDirectory(dir.file('tree/bin'));
			FileSystem.createDirectory(work);
			// no bin/test.js: a suite that ran would fail
			final engine: String = Sys.getEnv('HXQ_BIN') ?? FileSystem.fullPath('bin/apq.js');
			File.saveContent(dir.file('tree/bin/hxq'), 'cmd="$$1"; shift; exec node "$engine" "$$cmd" --lang haxe "$$@"\n');
			File.saveContent(dir.file('gate-sweep.json'), '{"pass":3,"fail":1,"skipParse":0,"fixtures":[]}');
			final plan: BatteryPlan = {
				repo: tree,
				work: work,
				cache: dir.file('cache'),
				head: 'h1',
				base: null,
				baseSuite: null,
				shards: 1,
				quick: true,
				snapshot: false,
				allowBlast: false,
				allow: [],
				client: null,
				jvmSkip: '--no-jvm',
				run: 'r',
				ownLease: false,
				gate: {
					tree: 't1',
					passed: true,
					toolchain: 'Haxe 4',
					fork: '',
					allow: [],
					rows: ['suite', 'corpus'],
					tests: 7,
					assertions: 9,
					sweep: dir.file('gate-sweep.json')
				},
				reused: ['suite', 'corpus']
			};
			File.saveContent(dir.file('work/plan.json'), BatteryPlanWriter.write(plan, JsonFormat.instance.compactWriteOptions));
			Assert.equals(0, Battery.main(['--rows', 'suite,corpus', '--plan', dir.file('work/plan.json')]));
			final report: BranchReportJson = BranchReportJsonParser.parse(File.getContent(dir.file('work/branch-suite.json')));
			Assert.same(
				[{ name: 'suite', outcome: 'skipped' }, { name: 'corpus', outcome: 'passed' }],
				report.steps.map(s -> {name: s.name, outcome: s.outcome })
			);
			final readings: Map<String, Int> = [for (r in report.readings) r.name => r.value];
			Assert.equals(7, readings['tests'], 'the next base\'s suite counts are the gate\'s');
			Assert.equals(3, readings['sweep-pass'], 'and its corpus counts are read off the gate\'s snapshot');
		});
	}

	/**
	 * The battery skips the jvm probe only when no jvm input moved since
	 * the base: the probe's build file alone, or a launch shim, runs it.
	 */
	@:pin('guard')
	public function testTheBatteryJvmSkipReadsTheGatesJvmInputs(): Void {
		final skipped: String = 'neither src/ nor the probe moved since ';
		TempDir.with(dir -> {
			final repo: String = dir.file('repo');
			FileSystem.createDirectory(repo);
			FileSystem.createDirectory('$repo/tools');
			git(repo, ['init', '-q', '-b', 'main']);
			File.saveContent('$repo/tools/jvm-portability.hxml', 'a');
			File.saveContent('$repo/notes.txt', 'a');
			git(repo, ['add', '.']);
			git(repo, ['commit', '-q', '-m', 'base']);
			final base: String = cmd('git -C $repo rev-parse HEAD').run().out.trim();
			File.saveContent('$repo/notes.txt', 'b');
			Assert.equals(skipped + base, Battery.jvmSkip(repo, base, null), 'a change outside the jvm inputs');
			File.saveContent('$repo/tools/jvm-portability.hxml', 'b');
			Assert.notEquals(skipped + base, Battery.jvmSkip(repo, base, null), 'the probe build file moved');
		});
	}

	@:pin('control')
	@:killer('M-BATTERY-IMPACT-DISPATCH-DROPPED')
	public function testASuiteThatRanOnlyTheReachedClassesLeavesTheCorpusToTheWholeSuite(): Void {
		TempDir.with(dir -> {
			final report: BranchReportJson = impactRun(dir, ['unit.cli.ApqDxTier5CliTest']);
			Assert.same(
				[{ name: 'suite', outcome: 'passed' }, { name: 'corpus', outcome: 'skipped' }],
				report.steps.map(s -> {name: s.name, outcome: s.outcome })
			);
			Assert.same(
				[1],
				report.readings.filter(r -> r.name == 'impact-classes').map(r -> r.value),
				'the selection, not the whole suite, was what ran'
			);
		});
	}

	@:pin('control')
	@:killer('M-BATTERY-IMPACT-DISPATCH-DROPPED')
	public function testASelectionOfNoClassSkipsTheSuiteAndTheCorpus(): Void {
		TempDir.with(dir -> {
			final report: BranchReportJson = impactRun(dir, []);
			Assert.same(
				[{ name: 'suite', outcome: 'skipped' }, { name: 'corpus', outcome: 'skipped' }],
				report.steps.map(s -> {name: s.name, outcome: s.outcome })
			);
		});
	}

	public function testAnImpactRunNamesItsClassesAndKeepsNoTotalsOfTheWholeSuite(): Void {
		final readings: Map<String, Int> = ['impact-classes' => 3, 'impact-tests' => 12, 'impact-assertions' => 40];
		Assert.same([
			'suite  impact — 3 class(es), 12 tests / 40 assertions (the whole suite runs after the land)',
			'corpus not run'
		], Battery.totalsLines(readings, 'abc', [10, 41]));
	}

	public function testAnImpactSnapshotCarriesTheBasesSweepAndSuiteLineSoTheNextLandNeedsNoBaseBattery(): Void {
		TempDir.with(dir -> {
			final work: String = dir.file('work');
			FileSystem.createDirectory(work);
			File.saveContent(dir.file('abc-suite.txt'), '10 41\n');
			File.saveContent(dir.file('abc-sweep.json'), '{"base":1}');
			final readings: Map<String, Int> = ['impact-classes' => 2, 'impact-tests' => 3, 'impact-assertions' => 4];
			final saved: Array<String> = [];
			Assert.isNull(Battery.keepSnapshot(dir.path, 'def', work, readings, file -> {
				saved.push(file);
				return new Result('sweep', {
					status: 0,
					out: '',
					err: '',
					failure: '',
					overflowed: false
				});
			}, 'abc'));
			Assert.same([], saved);
			Assert.equals('10 41', File.getContent(dir.file('def-suite.txt')).trim(), 'provisional, until the whole suite counts it');
			Assert.equals('{"base":1}', File.getContent(dir.file('def-sweep.json')));
		});
	}

	public function testAnImpactRunThatSweptKeepsItsOwnSweep(): Void {
		TempDir.with(dir -> {
			final work: String = dir.file('work');
			FileSystem.createDirectory(work);
			File.saveContent(dir.file('abc-sweep.json'), '{"base":1}');
			final readings: Map<String, Int> = ['impact-classes' => 2, 'sweep-pass' => 1];
			Assert.isNull(Battery.keepSnapshot(dir.path, 'def', work, readings, file -> {
				File.saveContent(file, '{"own":1}');
				return new Result('sweep', {
					status: 0,
					out: '',
					err: '',
					failure: '',
					overflowed: false
				});
			}, 'abc'));
			Assert.equals('{"own":1}', File.getContent(dir.file('def-sweep.json')));
			Assert.isFalse(FileSystem.exists(dir.file('def-suite.txt')), 'the base has no suite line to carry');
		});
	}

	private static function git(repo: String, words: Array<String>): Void {
		cmd('git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -C $repo $words').run().check();
	}

	/** The steps of the suite and corpus rows over a fake runner, for a plan whose suite is limited to `only`. */
	private static function impactRun(dir: TempDir, only: Array<String>): BranchReportJson {
		final tree: String = dir.file('tree');
		final work: String = dir.file('work');
		FileSystem.createDirectory(dir.file('tree/bin'));
		FileSystem.createDirectory(work);
		File.saveContent(dir.file('tree/bin/test.js'), GREEN_RUNNER);
		final engine: String = Sys.getEnv('HXQ_BIN') ?? FileSystem.fullPath('bin/apq.js');
		File.saveContent(dir.file('tree/bin/hxq'), 'cmd="$$1"; shift; exec node "$engine" "$$cmd" --lang haxe "$$@"\n');
		final plan: BatteryPlan = {
			repo: tree,
			work: work,
			cache: dir.file('cache'),
			head: 'h1',
			base: null,
			baseSuite: null,
			only: only,
			shards: 1,
			quick: true,
			snapshot: false,
			allowBlast: false,
			allow: [],
			client: null,
			jvmSkip: '--no-jvm',
			run: 'r',
			ownLease: false
		};
		File.saveContent(dir.file('work/plan.json'), BatteryPlanWriter.write(plan, JsonFormat.instance.compactWriteOptions));
		Assert.equals(0, Battery.main(['--rows', 'suite,corpus', '--plan', dir.file('work/plan.json')]));
		return BranchReportJsonParser.parse(File.getContent(dir.file('work/branch-suite.json')));
	}

}

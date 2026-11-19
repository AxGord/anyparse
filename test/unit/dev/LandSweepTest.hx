package unit.dev;

import anyparse.query.ExitCode;
import anyparse.util.Compare;
import dev.Land;
import dev.LandSweep;
import devkit.Cmd.cmd;
import devkit.Summary.Outcome;
import sys.FileSystem;
import sys.io.File;

using StringTools;

private typedef Change = { var path: String; var content: String; }

/** What a `Land.land` run of a sweep line over a scratch repository left behind. */
private typedef Swept = {

	var status: Int;
	var output: String;

	/** Whether main's HEAD is another commit than before the landing. */
	var moved: Bool;

	/** The message of main's HEAD after the landing. */
	var message: String;

	/** How many times the landing built its candidate. */
	var builds: Int;

	/** What main's tree holds at each path of the repository's `src` and at `rule.txt`. */
	var files: Map<String, String>;

}

/**
 * The `reapply` step of `dev land` (`LandSweep`) on scratch repositories. Main holds `src/A.hx` and `src/B.hx` with a
 * finding each (the word `BAD`), `src/C.hx` and `rule.txt` without; the branch's one commit is a sweep line's — the findings
 * rewritten, and `src/C.hx` and `rule.txt` changed as the rule it brings. The stand-in command reports every file of `src`
 * holding `BAD` and rewrites the word.
 */
@:nullSafety(Strict)
final class LandSweepTest extends Test {

	private static final BRANCH: String = 'batch/hxqb-S1';
	private static final COMMAND: String = 'hxq lint --rule r --fix src';
	private static final SWEPT: Array<Change> = [
		{ path: 'src/A.hx', content: 'GOOD a\n' },
		{ path: 'src/B.hx', content: 'GOOD b\n' },
		{ path: 'src/C.hx', content: 'rule v2\n' },
		{ path: 'rule.txt', content: 'r1\n' }
	];

	/** What a parallel landing brought to main: a footprint file changed where the branch changed it, and a new finding. */
	private static final PARALLEL: Array<Change> = [
		{ path: 'src/A.hx', content: 'BAD a2\n' },
		{ path: 'src/D.hx', content: 'BAD d\n' }
	];

	private static final QUEUE: String = 'header: x\ntasks:\n  - id: S1\n    status: running\n    text: |-\n      Sweep the rule.\n\n'
		+ '      sweep: hxq lint --rule r --fix src test\n    base: abc\n  - id: S2\n    status: running\n    text: |-\n'
		+ '      No marker here.\n';

	@:pin('control')
	@:killer('M-LAND-SWEEP-PICK-NOT-DEFERRED')
	public function testAFootprintFileAParallelLandChangedIsReappliedWithNoConflict(): Void {
		final run: Swept = landing(SWEPT, PARALLEL, COMMAND, sweeping());
		utest.Assert.equals(0, run.status, run.output);
		utest.Assert.equals('GOOD a2\n', run.files['src/A.hx'], 'main\'s line, rewritten by the command — never the branch\'s');
		utest.Assert.equals('GOOD d\n', run.files['src/D.hx'], 'a finding the parallel landing added is swept too');
		utest.Assert.equals('GOOD b\n', run.files['src/B.hx']);
		utest.Assert.isFalse(run.output.contains('could not merge'), run.output);
	}

	@:pin('control')
	@:killer('M-LAND-SWEEP-FOOTPRINT-IS-DIFF')
	public function testAFileOfTheCommitTheCommandDoesNotReportOnTheBaseMergesAsAnyPick(): Void {
		final run: Swept = landing(SWEPT, [], COMMAND, sweeping());
		utest.Assert.equals(0, run.status, run.output);
		utest.Assert.equals('rule v2\n', run.files['src/C.hx']);
		utest.Assert.equals('r1\n', run.files['rule.txt']);
	}

	@:pin('control')
	@:killer('M-LAND-SWEEP-FOOTPRINT-KEPT')
	public function testAFootprintFileLandsAsTheCommandWritesItNotAsTheBranchHasIt(): Void {
		final byHand: Array<Change> = [
			{ path: 'src/A.hx', content: 'GOOD a\n' },
			{ path: 'src/B.hx', content: 'GOOD b, and a hand edit\n' }
		];
		final run: Swept = landing(byHand, [], COMMAND, sweeping());
		utest.Assert.equals(0, run.status, run.output);
		utest.Assert.equals('GOOD b\n', run.files['src/B.hx']);
	}

	@:pin('control')
	@:killer('M-LAND-SWEEP-RESIDUE-UNMARKED')
	public function testFindingsTheCommandLeavesAreTheResidueExit(): Void {
		final run: Swept = landing(SWEPT, PARALLEL, COMMAND, sweeping('src/D.hx'));
		utest.Assert.equals((ExitCode.EXIT_RESIDUE: Int), run.status, run.output);
		utest.Assert.isFalse(run.moved);
		utest.Assert.stringContains('1 file(s) still carry findings after the sweep command, first src/D.hx', run.output);
	}

	@:pin('control')
	@:killer('M-LAND-SWEEP-NOT-NAMED')
	public function testTheCommitRecordsTheCommandInATrailer(): Void {
		final run: Swept = landing(SWEPT, PARALLEL, COMMAND, sweeping());
		utest.Assert.equals(0, run.status, run.output);
		utest.Assert.stringContains('Slice: S1\n${LandSweep.TRAILER}: $COMMAND', run.message);
	}

	@:pin('control')
	@:killer('M-LAND-SWEEP-STRAY-CONFLICT')
	public function testAConflictOutsideTheFootprintStillFailsThePick(): Void {
		final run: Swept = landing(SWEPT, PARALLEL.concat([{ path: 'rule.txt', content: 'r-main\n' }]), COMMAND, sweeping());
		utest.Assert.equals(1, run.status, run.output);
		utest.Assert.isFalse(run.moved);
		utest.Assert.stringContains('git could not merge', run.output);
		utest.Assert.stringContains('rule.txt', run.output);
	}

	@:pin('control')
	@:killer('M-LAND-SWEEP-EMPTY-FOOTPRINT')
	public function testACommitWithNoFootprintFileSkipsTheStepAndLandsAsItIs(): Void {
		final run: Swept = landing([{ path: 'rule.txt', content: 'r1\n' }], [], COMMAND, sweeping());
		utest.Assert.equals(0, run.status, run.output);
		utest.Assert.equals('r1\n', run.files['rule.txt']);
		utest.Assert.equals('BAD a\n', run.files['src/A.hx'], 'the command is not run for a commit that swept nothing');
		utest.Assert.isFalse(run.message.contains(LandSweep.TRAILER), run.message);
		utest.Assert.equals(1, run.builds);
	}

	@:pin('control')
	@:killer('M-LAND-SWEEP-FIX-FAILURE-IGNORED')
	public function testACommandThatDoesNotFinishFailsTheStepAndIsNotResidue(): Void {
		final run: Swept = landing(SWEPT, [], COMMAND, sweeping(null, true));
		utest.Assert.equals(1, run.status, run.output);
		utest.Assert.isFalse(run.moved);
		utest.Assert.stringContains('the engine died', run.output);
	}

	@:pin('control')
	@:killer('M-LAND-SWEEP-NO-REBUILD')
	public function testTheCandidateIsBuiltAgainAfterTheCommandRewroteIt(): Void {
		final run: Swept = landing(SWEPT, [], COMMAND, sweeping());
		utest.Assert.equals(0, run.status, run.output);
		utest.Assert.equals(2, run.builds);
	}

	public function testAFootprintThatCannotBeListedFailsTheStep(): Void {
		final blind: ReapplyTools = { findings: (engine, tree, command) -> Unlisted('unknown rule "r"'), fix: (tree, command) -> Passed };
		final run: Swept = landing(SWEPT, [], COMMAND, blind);
		utest.Assert.equals(1, run.status, run.output);
		utest.Assert.isFalse(run.moved);
		utest.Assert.stringContains('no footprint of the sweep command on the base tree of `$BRANCH`: unknown rule "r"', run.output);
	}

	public function testACommandThatIsNotAPlainLintFixFailsTheStep(): Void {
		final run: Swept = landing(SWEPT, [], 'make sweep', sweeping());
		utest.Assert.equals(1, run.status, run.output);
		utest.Assert.isFalse(run.moved);
		utest.Assert.stringContains('the sweep command `make sweep` is not a plain', run.output);
	}

	/** A line with no sweep command: no `reapply` row, one build, no trailer, and a conflict fails the pick. */
	@:pin('guard')
	public function testALineWithoutTheMarkerLandsAsBefore(): Void {
		final green: Swept = landing(SWEPT, [], null, sweeping());
		utest.Assert.equals(0, green.status, green.output);
		utest.Assert.isFalse(green.output.contains('reapply'), green.output);
		utest.Assert.equals(1, green.builds);
		utest.Assert.isFalse(green.message.contains(LandSweep.TRAILER), green.message);
		utest.Assert.equals('GOOD a\n', green.files['src/A.hx']);
		final conflicted: Swept = landing(SWEPT, PARALLEL, null, sweeping());
		utest.Assert.equals(1, conflicted.status, conflicted.output);
		utest.Assert.isFalse(conflicted.moved);
		utest.Assert.stringContains('git could not merge src/A.hx', conflicted.output);
	}

	@:pin('control')
	@:killer('M-LAND-SWEEP-MARKER-ANY-ROW')
	public function testTheCommandIsTheMarkerRowOfTheLinesText(): Void {
		utest.Assert.equals('hxq lint --rule r --fix src test', LandSweep.commandOf(QUEUE, 'S1'));
		utest.Assert.isNull(LandSweep.commandOf(QUEUE, 'S2'));
		utest.Assert.isNull(LandSweep.commandOf(QUEUE, 'S3'));
	}

	@:pin('control')
	@:killer('M-LAND-SWEEP-FIX-NOT-REQUIRED')
	public function testOnlyAPlainLintWithFixIsACommandALandingRuns(): Void {
		utest.Assert.same(['lint', '--rule', 'r', '--fix', 'src', 'test'], LandSweep.wordsOf(' hxq  lint --rule r --fix src test '));
		utest.Assert.same(['lint', '--fix', 'src'], LandSweep.wordsOf('apq lint --fix src'));
		utest.Assert.isNull(LandSweep.wordsOf('hxq lint --rule r src'));
		utest.Assert.isNull(LandSweep.wordsOf('hxq fmt --fix src'));
		utest.Assert.isNull(LandSweep.wordsOf('sh lint --fix src'));
		utest.Assert.isNull(LandSweep.wordsOf('hxq lint --fix src; rm -r x'));
		utest.Assert.isNull(LandSweep.wordsOf('hxq lint --fix "src"'));
	}

	@:pin('control')
	@:killer('M-LAND-SWEEP-LISTING-KEEPS-FIX-ONLY')
	public function testTheListingIsTheCommandWithoutItsWriteAsAJsonReport(): Void {
		utest.Assert.same(['lint', '--rule', 'r', 'src', '--format', 'json'], LandSweep.listing(['lint', '--rule', 'r', '--fix', 'src']));
		utest.Assert.same(['lint', '--rule', 'r', '--fix-probes', '8', 'src', '--format', 'json'], LandSweep.listing([
			'lint',
			'--rule',
			'r',
			'--fix',
			'--review-budget',
			'400',
			'--fix-probes',
			'8',
			'src'
		]));
		utest.Assert.same(['lint', 'src', '--format', 'json'], LandSweep.listing(['lint', '--fix', '--review-budget=400', 'src']));
	}

	@:pin('control')
	@:killer('M-LAND-SWEEP-REPORT-OPTION-ACCEPTED')
	public function testACommandThatShapesItsReportOrItsExitIsRefused(): Void {
		for (option in [
			'--fail-on warning',
			'--format json',
			'--baseline b.json',
			'--range 1:4',
			'--changed-since HEAD',
			'--fail-on=error'
		]) utest.Assert.isNull(LandSweep.wordsOf('hxq lint --rule r --fix $option src'), option);
		utest.Assert.notNull(LandSweep.wordsOf('hxq lint --rule r --fix --review-budget 400 --fix-probes 8 src'));
	}

	@:pin('control')
	@:killer('M-LAND-SWEEP-OUTSIDE-PATH-ACCEPTED')
	public function testACommandOverAPathFromOutsideTheTreeIsRefused(): Void {
		utest.Assert.isNull(LandSweep.wordsOf('hxq lint --rule r --fix /abs/tree/src'));
		utest.Assert.isNull(LandSweep.wordsOf('hxq lint --rule r --fix ../other/src'));
		utest.Assert.isNull(LandSweep.wordsOf('hxq lint --rule r --fix src/../../other'));
		utest.Assert.notNull(LandSweep.wordsOf('hxq lint --rule r --fix src/a test'));
	}

	@:pin('control')
	@:killer('M-LAND-SWEEP-CREATED-NOT-STAGED')
	public function testAFileTheCommandCreatesIsInTheCommit(): Void {
		final run: Swept = landing(SWEPT, [], COMMAND, sweeping(null, false, 'src/ambient.hx'));
		utest.Assert.equals(0, run.status, run.output);
		utest.Assert.equals('ambient\n', run.files['src/ambient.hx']);
	}

	public function testTheFilesOfAReportAreEachOnceFromTheTreesRoot(): Void {
		final record: String = '"severity":"warning","rule":"r","message":"m"';
		final report: String = '[{"file":"./src/A.hx",$record},{"file":"src/A.hx",$record},{"file":"test/B.hx",$record}]';
		utest.Assert.same(Listed(['src/A.hx', 'test/B.hx']), LandSweep.filesOf(report));
		utest.Assert.same(Listed([]), LandSweep.filesOf('[]'));
		utest.Assert.isTrue(LandSweep.filesOf('apq lint: unknown rule "r"').match(Unlisted(_)));
	}

	/**
	 * The stand-in command; it leaves the findings of `stubborn` alone, does not finish at all when `dies`, and makes the file
	 * `creates` when one is named.
	 */
	private static function sweeping(?stubborn: String, dies: Bool = false, ?creates: String): ReapplyTools {
		return {
			findings: (engine, tree, command) -> Listed(carrying(tree)),
			fix: (tree, command) -> {
				if (dies) return Failed('the engine died');
				for (path in carrying(tree)) if (path != stubborn)
					File.saveContent('$tree/$path', File.getContent('$tree/$path').replace('BAD', 'GOOD'));
				if (creates != null) File.saveContent('$tree/$creates', 'ambient\n');
				return Passed;
			}
		};
	}

	/** The files of `tree`'s `src` that hold a finding, in name order. */
	private static function carrying(tree: String): Array<String> {
		final names: Array<String> = FileSystem.readDirectory('$tree/src');
		names.sort(Compare.compareString);
		return [
			for (name in names) if (File.getContent('$tree/src/$name').contains('BAD')) 'src/$name'
		];
	}

	/**
	 * The branch whose one commit writes `side` landed on a main that `parallel` moved since (not at all when empty), as the
	 * landing of a line whose sweep command is `command` (none when null).
	 */
	private static function landing(side: Array<Change>, parallel: Array<Change>, command: Null<String>, tools: ReapplyTools): Swept {
		return devkit.TempDir.with(dir -> {
			final repo: String = dir.file('repo');
			FileSystem.createDirectory('$repo/src');
			git(repo, ['init', '-q', '-b', 'main']);
			write(repo, [
				{ path: 'src/A.hx', content: 'BAD a\n' },
				{ path: 'src/B.hx', content: 'BAD b\n' },
				{ path: 'src/C.hx', content: 'fine\n' },
				{ path: 'rule.txt', content: 'r0\n' },
				{ path: '.gitignore', content: 'bin/*.out\n# $repo\n' }
			]);
			commit(repo, 'base');
			git(repo, ['checkout', '-q', '-b', BRANCH]);
			write(repo, side);
			commit(repo, 'side');
			git(repo, ['checkout', '-q', 'main']);
			if (parallel.length > 0) {
				write(repo, parallel);
				commit(repo, 'main moved');
			}
			final before: String = cmd('git -C $repo rev-parse HEAD').run().out.trim();
			final printed: Array<String> = [];
			var builds: Int = 0;
			final status: Int = Land.land({
				repo: repo,
				branch: BRANCH,
				logs: dir.file('logs'),
				message: null,
				battery: null,
				compile: (tree, log, _) -> {
					FileSystem.createDirectory('$tree/bin');
					File.saveContent('$tree/bin/engine.out', 'built\n');
					builds++;
					return Passed;
				},
				format: { rewrite: (tree, files) -> Passed, changes: (tree, base, files) -> '', settled: (tree, files) -> Passed },
				reapply: command,
				reapplyTools: tools,
				exec: (words, tree, log) -> Passed,
				merged: Land.mergedPaths,
				print: line -> printed.push(line)
			});
			final names: Array<String> = FileSystem.readDirectory('$repo/src').map(name -> 'src/$name').concat(['rule.txt']);
			{
				status: status,
				output: printed.join('\n'),
				moved: cmd('git -C $repo rev-parse HEAD').run().out.trim() != before,
				message: cmd('git -C $repo log -1 --format=%B').run().out.trim(),
				builds: builds,
				files: [ for (name in names) name => File.getContent('$repo/$name') ]
			};
		});
	}

	private static function write(repo: String, changes: Array<Change>): Void {
		for (change in changes) File.saveContent('$repo/${change.path}', change.content);
	}

	private static function commit(repo: String, message: String): Void {
		git(repo, ['add', '.']);
		git(repo, ['commit', '-q', '-m', message]);
	}

	private static function git(repo: String, words: Array<String>): Void {
		cmd('git -c user.name=land -c user.email=land@example.com -c commit.gpgsign=false -C $repo $words').run().check();
	}

}

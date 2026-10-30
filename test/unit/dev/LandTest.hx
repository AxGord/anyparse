package unit.dev;

import dev.Land;
import devkit.Args.UsageError;
import devkit.Cmd.cmd;
import devkit.Summary.Outcome;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `dev land` over a scratch repository: a slice of one commit lands on `main` linearly with its `Slice` trailer, a step after
 * the pick that does not pass — one that threw as much as one that failed — takes it back, and the battery's flags follow
 * the lease.
 */
@:nullSafety(Strict)
final class LandTest extends Test {

	/** The slice branch of the scratch repository; its id, `S1`, is what the trailer names. */
	private static inline final BRANCH: String = 'batch/hxqb-S1';

	/** A merge driver that writes its own text over ours and reports the merge. */
	private static inline final DRIVER_STUB: String = "const fs = require('fs'); const a = process.argv;\n"
		+ "if (a[2] === 'merge-file') { fs.writeFileSync(a[4], 'by the driver\\n');\n"
		+ "process.stderr.write('auto-merged: ' + a[a.indexOf('--path') + 1] + ' (stub)\\n'); }\n";

	/** A merge driver that leaves one place both sides changed, as `apq merge-file` reports it. */
	private static inline final CONFLICT_STUB: String = "const fs = require('fs'); const a = process.argv;\n"
		+ "if (a[2] === 'merge-file') { fs.writeFileSync(a[4], 'conflicted\\n');\n"
		+ "process.stderr.write('merge-conflict: ' + a[a.indexOf('--path') + 1] + ' C.f (ours changed, theirs changed)\\n');\n"
		+ 'process.exitCode = 1; }\n';

	/** A merge driver that writes the choices it was handed over ours. */
	private static inline final CHOICES_STUB: String = "const fs = require('fs'); const a = process.argv;\n"
		+ "if (a[2] === 'merge-file') { const i = a.indexOf('--choices');\n"
		+ "fs.writeFileSync(a[4], i < 0 ? 'none\\n' : fs.readFileSync(a[i + 1])); }\n";

	@:pin('control')
	@:killer('M-LAND-NOT-RUN-KEEPS-MERGE')
	public function testABuildThatThrewTakesThePickBack(): Void {
		final run: Landing = landing(() -> throw 'the compiler could not be started');
		Assert.equals(1, run.status);
		Assert.isTrue(run.output.indexOf('not run') >= 0);
		Assert.equals(2, run.builds);
		Assert.isFalse(run.merging);
		Assert.equals('', run.dirty);
		Assert.isFalse(run.merged);
	}

	public function testABuildThatFailedTakesThePickBack(): Void {
		final run: Landing = landing(() -> Failed('no good'));
		Assert.equals(1, run.status);
		Assert.isFalse(run.merging);
		Assert.equals('', run.dirty);
		Assert.isFalse(run.merged);
	}

	public function testAGreenBuildLeavesThePickCommitted(): Void {
		final run: Landing = landing(() -> Passed);
		Assert.equals(0, run.status);
		Assert.equals(1, run.builds);
		Assert.isTrue(run.merged);
	}

	public function testTheBatteryIsQuickUnlessAskedFull(): Void {
		Assert.same(['--quick'], Land.batteryFlags(false, false, false, null, []));
		Assert.same([], Land.batteryFlags(false, false, true, null, []));
		Assert.same(['--allow-blast', '--snapshot', '--quick'], Land.batteryFlags(true, true, false, null, []));
	}

	public function testTheSuiteTakesTheShardsALeaseLeavesBesideTheLightBranches(): Void {
		Assert.same(['--quick', '-n', '4'], Land.batteryFlags(false, false, false, 8, []));
		Assert.same(['--quick', '-n', '1'], Land.batteryFlags(false, false, false, 2, []));
		Assert.same(['--allow', 'corpus', '--allow', 'lint', '--quick'], Land.batteryFlags(false, false, false, null, ['corpus', 'lint']));
	}

	public function testAQuietLandingRunsTheQuickBattery(): Void {
		final run: Landing = landing(() -> Passed, 'docs/note.md', { full: false, landed: 0 });
		Assert.equals(0, run.status);
		Assert.same([['--quick', '--base', run.base]], run.flags);
		Assert.isTrue(run.output.indexOf('battery quick') >= 0, run.output);
	}

	@:pin('control')
	@:killer('M-LAND-DIVERGENCE-PATH-STAYS-QUICK')
	public function testAPathWhereShardsDivergeRunsTheFullBattery(): Void {
		final run: Landing = landing(() -> Passed, 'test/testkit/Extra.hx', { full: false, landed: 0 });
		Assert.equals(0, run.status);
		Assert.same([['--base', run.base]], run.flags);
		Assert.isTrue(run.output.indexOf('battery full: touches test/testkit/Extra.hx') >= 0, run.output);
	}

	@:pin('control')
	@:killer('M-LAND-TENTH-LANDING-STAYS-QUICK')
	public function testTheTenthLandingRunsTheFullBattery(): Void {
		final ninth: Landing = landing(() -> Passed, 'docs/note.md', { full: false, landed: 8 });
		Assert.same([['--quick', '--base', ninth.base]], ninth.flags);
		final tenth: Landing = landing(() -> Passed, 'docs/note.md', { full: false, landed: 9 });
		Assert.same([['--base', tenth.base]], tenth.flags);
		Assert.isTrue(tenth.output.indexOf('battery full: landing 10') >= 0, tenth.output);
	}

	public function testAskedForFullTheBatteryIsFullWhateverTheMergeBrings(): Void {
		final run: Landing = landing(() -> Passed, 'docs/note.md', { full: true, landed: 0 });
		Assert.same([['--base', run.base]], run.flags);
		Assert.isTrue(run.output.indexOf('battery full: --full') >= 0, run.output);
	}

	public function testEveryPathWhereShardsAndTheMonolithCanDivergeAsksForFull(): Void {
		for (path in [
			'test/testkit/FixtureCompileCache.hx',
			'tools/src/dev/Shard.hx',
			'src/anyparse/query/ShardPlan.hx',
			'src/anyparse/query/SharedParseTier.hx',
			'src/anyparse/query/FormatConfigDiscovery.hx',
			'src/anyparse/grammar/haxe/HaxeQueryPlugin.hx',
			'src/anyparse/macro/QueryWalkerCodegen.hx',
			'src/anyparse/runtime/Parser.hx',
			'src/anyparse/query/cli/TestTranscript.hx',
			'test/RunTests.hx',
			'tools/src/dev/Battery.hx'
		]) Assert.notNull(Land.fullReason(['docs/a.md', path], 1, false, Land.FULL_EVERY), path);
		for (path in [
			'docs/testing.md',
			'src/anyparse/query/Linter.hx',
			'test/unit/query/ShardPlanTest.hx',
			'tools/src/dev/Land.hx'
		]) Assert.isNull(Land.fullReason([path], 1, false, Land.FULL_EVERY), path);
	}

	public function testPathsGitCannotSayAskForFull(): Void {
		Assert.notNull(Land.fullReason(null, 1, false, Land.FULL_EVERY));
	}

	public function testTheEveryRuleIsSwitchedOffByANonPositiveInterval(): Void {
		Assert.isNull(Land.fullReason(['docs/a.md'], 10, false, 0));
		Assert.notNull(Land.fullReason(['docs/a.md'], 10, false, 10));
	}

	public function testARedBatteryNamesItsModeInTheFailure(): Void {
		final quick: Landing = landing(() -> Passed, 'docs/note.md', { full: false, landed: 0, fails: true });
		Assert.equals(1, quick.status);
		Assert.isTrue(quick.output.indexOf('battery quick — the battery is red') >= 0, quick.output);
		final full: Landing = landing(() -> Passed, 'test/testkit/Extra.hx', { full: false, landed: 0, fails: true });
		Assert.isTrue(full.output.indexOf('battery full: touches test/testkit/Extra.hx — the battery is red') >= 0, full.output);
	}

	public function testNoBatteryCountsNoLanding(): Void {
		final run: Landing = landing(() -> Passed, 'docs/note.md');
		Assert.equals(0, run.status);
		Assert.same([], run.flags);
		Assert.isFalse(run.tallied);
		Assert.isTrue(landing(() -> Passed, 'docs/note.md', { full: false, landed: 0 }).tallied);
	}

	public function testMergedPathsNobodyCanReadRunTheFullBattery(): Void {
		final run: Landing = landing(() -> Passed, 'docs/note.md', { full: false, landed: 0, unreadable: true });
		Assert.same([['--base', run.base]], run.flags);
		Assert.isTrue(run.output.indexOf('battery full: the merged paths are unknown') >= 0, run.output);
	}

	public function testAFileRenamedOutOfTheTestKitAsksForFull(): Void {
		final run: Landing = landing(() -> Passed, 'docs/moved.md', { full: false, landed: 0 }, 'test/testkit/Old.hx');
		Assert.same([['--base', run.base]], run.flags);
		Assert.isTrue(run.output.indexOf('battery full: touches test/testkit/Old.hx') >= 0, run.output);
	}

	public function testTheSnapshotDirectoryDefaultsUnderHome(): Void {
		Assert.equals('/x/cache', Land.cacheDir(name -> name == 'ANYPARSE_BLAST_CACHE' ? '/x/cache' : '/home/u'));
		Assert.equals('/home/u/anyparse-blast-cache', Land.cacheDir(name -> name == 'HOME' ? '/home/u' : null));
	}

	@:pin('control')
	@:killer('M-LAND-COMMIT-LOSES-AUTHOR')
	public function testASliceLandsAsOneLinearCommitOnTopOfMain(): Void {
		final run: Landing = landing(() -> Passed);
		Assert.equals(0, run.status);
		Assert.isTrue(run.merged);
		Assert.equals(1, run.parents);
		Assert.equals(2, run.commits);
		Assert.equals('land', run.author);
	}

	public function testMainThatMovedOnTakesTheSliceWithoutAMergeCommit(): Void {
		final run: Landing = landing(() -> Passed, 'b.txt', null, null, { onMain: [{ path: 'c.txt', content: 'c\n' }], read: ['c.txt'] });
		Assert.equals(0, run.status);
		Assert.isTrue(run.merged);
		Assert.equals(1, run.parents);
		Assert.equals(3, run.commits);
		Assert.equals('c\n', run.files['c.txt']);
	}

	@:pin('control')
	@:killer('M-LAND-NO-SLICE-TRAILER')
	public function testTheCommitCarriesASliceTrailerNamingTheBranchsSlice(): Void {
		final run: Landing = landing(() -> Passed);
		Assert.isTrue(run.message.startsWith('side\n'), run.message);
		Assert.isTrue(run.message.endsWith('\n\nSlice: S1'), run.message);
	}

	public function testASliceTrailerTheMessageHasIsKept(): Void {
		final run: Landing = landing(() -> Passed, 'b.txt', null, null, { sideMessage: 'side\n\nSlice: OTHER' });
		Assert.equals('side\n\nSlice: OTHER', run.message);
	}

	public function testTheMessageAskedForReplacesTheBranchsOwn(): Void {
		final run: Landing = landing(() -> Passed, 'b.txt', null, null, { message: 'asked for' });
		Assert.equals('asked for\n\nSlice: S1', run.message);
	}

	public function testTheMetricTrailersFollowTheSliceTrailer(): Void {
		final trailers: Array<String> = Land.metricTrailers('2', '150000');
		Assert.same(['Review-Rounds: 2', 'Tokens: 150000'], trailers);
		final run: Landing = landing(() -> Passed, 'b.txt', null, null, { trailers: trailers });
		Assert.equals('side\n\nSlice: S1\nReview-Rounds: 2\nTokens: 150000', run.message);
	}

	public function testAMetricThatIsNoCountIsRefused(): Void {
		Assert.same([], Land.metricTrailers(null, null));
		Assert.raises(() -> Land.metricTrailers('two', null), devkit.Args.UsageError);
	}

	public function testTheSliceIdIsTheBranchNameWithoutItsPrefix(): Void {
		Assert.equals('LAND-2', Land.sliceId('batch/hxqb-LAND-2'));
		Assert.equals('FB2b', Land.sliceId('hxqb-FB2b'));
		Assert.equals('odd', Land.sliceId('feature/odd'));
		Assert.equals('plain', Land.sliceId('plain'));
	}

	@:pin('control')
	@:killer('M-LAND-ANY-NUMBER-OF-COMMITS')
	public function testABranchOfSeveralCommitsIsRefusedAndMainStaysPut(): Void {
		final run: Landing = landing(() -> Passed, 'b.txt', null, null, { moreCommits: [{ path: 'c.txt', content: 'c\n' }] });
		Assert.equals(1, run.status);
		Assert.isTrue(run.output.indexOf('carries 2 commits') >= 0, run.output);
		Assert.isFalse(run.moved);
		Assert.equals('', run.dirty);
		Assert.equals(0, run.builds);
	}

	public function testABranchMainAlreadyHoldsIsRefused(): Void {
		final run: Landing = landing(() -> Passed, 'b.txt', null, null, { preLanded: true });
		Assert.equals(1, run.status);
		Assert.isTrue(run.output.indexOf('has no commit the checked-out branch lacks') >= 0, run.output);
		Assert.isFalse(run.moved);
	}

	@:pin('control')
	@:killer('M-LAND-NOT-RUN-KEEPS-MERGE')
	public function testAConflictTakesThePickBackWithNothingLeftHanging(): Void {
		final run: Landing = landing(
			() -> Passed, 'a.txt', null, null, { onMain: [{ path: 'a.txt', content: 'main\n' }], read: ['a.txt'] }
		);
		Assert.equals(1, run.status);
		Assert.isTrue(run.output.indexOf('git could not merge a.txt') >= 0, run.output);
		Assert.isFalse(run.merging);
		Assert.isFalse(run.moved);
		Assert.equals('', run.dirty);
		Assert.equals('main\n', run.files['a.txt']);
		Assert.equals(0, run.builds);
	}

	public function testAnAppendOnlyFileBothSidesAppendedToKeepsBothLines(): Void {
		final run: Landing = landing(() -> Passed, 'b.txt', null, null, {
			attributes: 'notes.md merge=union\n',
			base: [{ path: 'notes.md', content: 'x\n' }],
			onSide: [{ path: 'notes.md', content: 'x\nside\n' }],
			onMain: [{ path: 'notes.md', content: 'x\nmain\n' }],
			read: ['notes.md']
		});
		Assert.equals(0, run.status);
		Assert.equals('x\nmain\nside\n', run.files['notes.md']);
	}

	public function testTheGrammarDriverIsNamedAndWhatItMergedIsADetailLine(): Void {
		final run: Landing = landing(() -> Passed, 'b.txt', null, null, {
			attributes: 'arms.json merge=anyparse\n',
			base: [
				{ path: 'arms.json', content: 'x\n' },
				{ path: 'bin/apq.js', content: DRIVER_STUB }
			],
			onSide: [{ path: 'arms.json', content: 'side\n' }],
			onMain: [{ path: 'arms.json', content: 'main\n' }],
			read: ['arms.json']
		});
		Assert.equals(0, run.status, run.output);
		Assert.equals('by the driver\n', run.files['arms.json']);
		Assert.isTrue(run.output.indexOf('auto-merged: arms.json (stub)') >= 0, run.output);
	}

	public function testAPlaceTheDriverLeftFailsThePickWithABrief(): Void {
		final run: Landing = landing(() -> Passed, 'b.txt', null, null, {
			attributes: 'arms.json merge=anyparse\n',
			base: [
				{ path: 'arms.json', content: 'x\n' },
				{ path: 'bin/apq.js', content: CONFLICT_STUB }
			],
			onSide: [{ path: 'arms.json', content: 'side\n' }],
			onMain: [{ path: 'arms.json', content: 'main\n' }],
			read: ['arms.json']
		});
		Assert.equals(1, run.status);
		Assert.isTrue(run.output.indexOf('1 place(s) to choose') >= 0, run.output);
		Assert.isFalse(run.merging);
		Assert.equals('main\n', run.files['arms.json']);
		Assert.isTrue(run.brief.indexOf('### `C.f` — ours changed, theirs changed') >= 0, run.brief);
		Assert.isTrue(run.brief.indexOf('--resolve \'arms.json#C.f=theirs\'') >= 0, run.brief);
	}

	public function testAResolutionReachesTheDriver(): Void {
		final run: Landing = landing(() -> Passed, 'b.txt', null, null, {
			attributes: 'arms.json merge=anyparse\n',
			base: [
				{ path: 'arms.json', content: 'x\n' },
				{ path: 'bin/apq.js', content: CHOICES_STUB }
			],
			onSide: [{ path: 'arms.json', content: 'side\n' }],
			onMain: [{ path: 'arms.json', content: 'main\n' }],
			resolve: ['arms.json#C (head)=theirs'],
			read: ['arms.json']
		});
		Assert.equals(0, run.status, run.output);
		Assert.equals('arms.json\tC (head)\ttheirs\n', run.files['arms.json']);
	}

	public function testAResolutionOfAnotherShapeIsRefused(): Void {
		Assert.equals('a.hx\tC.f#2\tboth\n', Land.choiceLine('a.hx#C.f#2=both'));
		Assert.raises(() -> Land.choiceLine('a.hx=ours'), UsageError);
		Assert.raises(() -> Land.choiceLine('a.hx#C.f=mine'), UsageError);
		Assert.equals("'/a b/it'\\''s'", Land.shellQuoted("/a b/it's"));
	}

	@:pin('control')
	@:killer('M-LAND-ARMS-REGISTRY-ASKS-FULL')
	public function testTheArmRegistryAloneAsksForNoFullBattery(): Void {
		Assert.isNull(Land.fullReason(['test/testkit/mutation-arms.json', 'docs/a.md'], 1, false, Land.FULL_EVERY));
		Assert.equals(
			'touches test/testkit/Extra.hx',
			Land.fullReason(['test/testkit/mutation-arms.json', 'test/testkit/Extra.hx'], 1, false, Land.FULL_EVERY)
		);
	}

	@:pin('control')
	@:killer('M-LAND-ROLLBACK-RESETS-HARD')
	public function testARollbackKeepsWhatTheUserEditedMeanwhile(): Void {
		final run: Landing = landing(
			() -> Failed('no good'), 'b.txt', null, null,
			{ during: repo -> File.saveContent('$repo/a.txt', 'user edit\n'), read: ['a.txt'] }
		);
		Assert.equals(1, run.status);
		Assert.equals('user edit\n', run.files['a.txt']);
		Assert.equals('M a.txt', run.dirty);
		Assert.isFalse(run.merged);
		Assert.isFalse(run.merging);
		Assert.isFalse(run.moved);
	}

	public function testARollbackRefusedForAFileOfThePickLeavesTheTreeToTheUser(): Void {
		final run: Landing = landing(
			() -> Failed('no good'), 'b.txt', null, null,
			{ during: repo -> File.saveContent('$repo/b.txt', 'user edit\n'), read: ['b.txt'] }
		);
		Assert.equals(1, run.status);
		Assert.equals('user edit\n', run.files['b.txt']);
		Assert.isTrue(run.output.indexOf('`git reset --merge` refused') >= 0, run.output);
		Assert.isTrue(run.output.indexOf('b.txt') >= 0, run.output);
		Assert.equals(1, run.builds);
	}

	@:pin('control')
	@:killer('M-LAND-ROLLBACK-IGNORES-MOVED-HEAD')
	public function testARollbackNeverResetsAHeadThatMovedMeanwhile(): Void {
		final run: Landing = landing(
			() -> Failed('no good'), 'b.txt', null, null,
			{ during: repo -> git(repo, ['commit', '-q', '--allow-empty', '-m', 'the user commits']) }
		);
		Assert.equals(1, run.status);
		Assert.isTrue(run.output.indexOf('HEAD moved since the pick began') >= 0, run.output);
		Assert.equals(2, run.commits);
		Assert.equals('the user commits', run.message);
		Assert.equals(1, run.builds);
	}

	@:pin('control')
	@:killer('M-LAND-LANDED-AGAIN-PASSES')
	public function testABranchLandedAlreadyIsRefusedBeforeTheBuild(): Void {
		final run: Landing = landing(() -> Passed, 'b.txt', null, null, { again: true });
		Assert.equals(0, run.status);
		Assert.equals(1, run.againStatus);
		Assert.isTrue(run.againOutput.indexOf('`batch/hxqb-S1` is landed already as ') >= 0, run.againOutput);
		Assert.equals(1, run.builds);
		Assert.equals(2, run.commits);
	}

	@:pin('control')
	@:killer('M-LAND-LANDED-BY-PATCH-PASSES')
	public function testABranchWhosePatchMainHoldsWithNoTrailerIsRefused(): Void {
		final run: Landing = landing(() -> Passed, 'b.txt', null, null, { handPicked: true });
		Assert.equals(1, run.status);
		Assert.isTrue(run.output.indexOf('is landed already as a commit with the same patch') >= 0, run.output);
		Assert.equals(0, run.builds);
	}

	public function testTheBatteryIsPinnedToTheCommitTheLandingMergedOnto(): Void {
		final run: Landing = landing(() -> Passed, 'docs/note.md', { full: false, landed: 0 });
		Assert.equals(run.headBefore.substr(0, dev.Battery.KEY_LENGTH), run.base);
		Assert.same([['--quick', '--base', run.base]], run.flags);
		Assert.equals('', run.builtFrom, 'a base the cache holds is not made again');
	}

	public function testABaseWithoutASnapshotGetsOneFromADetachedTreeOfIt(): Void {
		final run: Landing = landing(() -> Passed, 'docs/note.md', { full: false, landed: 0, noSnapshot: true });
		Assert.equals(0, run.status);
		Assert.equals(2, run.flags.length);
		Assert.same(['--snapshot', '--quick', '--no-base', '--repo'], run.flags[0].slice(0, 4));
		Assert.equals(run.headBefore, run.builtFrom, 'the snapshot is taken of the commit landed onto, not of the landing');
		Assert.isFalse(run.builtTreeLeft);
		Assert.same(['--quick', '--base', run.base], run.flags[1]);
		Assert.isTrue(run.output.indexOf('had no snapshot — made') >= 0, run.output);
	}

	public function testASnapshotOfTheBaseThatCannotBeMadeFailsTheLanding(): Void {
		final run: Landing = landing(() -> Passed, 'docs/note.md', {
			full: false,
			landed: 0,
			noSnapshot: true,
			baseFails: true
		});
		Assert.equals(1, run.status);
		Assert.equals(1, run.flags.length, 'the landing\'s own battery does not run against a base nobody could snapshot');
		Assert.isTrue(run.output.indexOf('could not be made') >= 0, run.output);
		Assert.isFalse(run.builtTreeLeft);
		Assert.isFalse(run.moved, 'the base is ensured before the pick, so main is untouched');
		Assert.isFalse(run.merged);
		Assert.equals(0, run.builds);
		Assert.equals('', run.dirty);
	}

	public function testARedBatteryOfTheBaseStillServesAsTheBase(): Void {
		final run: Landing = landing(() -> Passed, 'docs/note.md', {
			full: false,
			landed: 0,
			noSnapshot: true,
			baseRed: true
		});
		Assert.equals(0, run.status);
		Assert.equals(2, run.flags.length);
		Assert.same(['--quick', '--base', run.base], run.flags[1]);
		Assert.isTrue(run.output.indexOf('was red — its snapshot is the base all the same') >= 0, run.output);
	}

	/**
	 * A repository whose `batch/hxqb-S1` branch adds a file in one commit, landed on `main` with `build` standing in for the
	 * compiler: the first call is the build after the pick, the second the rebuild after a rollback. `setup` shapes the
	 * repository further.
	 */
	private static function landing(
		build: () -> Outcome, added: String = 'b.txt', ?battery: Battery, ?renameFrom: String, ?setup: Setup
	): Landing {
		final shape: Setup = setup ?? {};
		return TempDir.with(dir -> {
			final repo: String = dir.file('repo');
			scaffold(repo, added, renameFrom, shape);
			final headBefore: String = cmd('git -C $repo rev-parse HEAD').run().out.trim();
			final base: String = headBefore.substr(0, dev.Battery.KEY_LENGTH);
			final logs: String = dir.file('logs');
			FileSystem.createDirectory(logs);
			final printed: Array<String> = [];
			final flags: Array<Array<String>> = [];
			var builds: Int = 0;
			final cache: String = dir.file('cache');
			if (battery != null && battery.landed > 0) {
				makeDirectories('$cache/landings');
				File.saveContent('$cache/landings/${battery.landed}', '');
			}
			seedBase(battery, cache, base);
			var builtFrom: String = '';
			var builtTree: String = '';
			final red: Bool = battery != null && battery.fails == true;

			final unreadable: Bool = battery != null && battery.unreadable == true;
			final request: Null<BatteryRequest> = battery == null ? null : {
				allowBlast: false,
				snapshot: false,
				allow: [],
				full: battery.full,
				leased: null,
				cache: cache,
				every: Land.FULL_EVERY
			};
			function go(): Int return Land.land({
				repo: repo,
				branch: BRANCH,
				logs: logs,
				message: shape.message,
				trailers: shape.trailers,
				resolve: shape.resolve,
				battery: request,
				compile: (tree, log) -> ++builds == 1 ? interfere(shape.during, repo, build) : Passed,
				exec: (words, tree, log) -> {
					flags.push(words);
					final at: Int = words.indexOf('--repo');
					if (at >= 0) {
						builtTree = words[at + 1];
						builtFrom = cmd('git -C $builtTree rev-parse HEAD').run().out.trim();
					}
					return if (at >= 0)
						makeBase(battery, cache, base)
					else if (red)
						Failed('the battery is red')
					else
						Passed;
				},
				merged: tree -> unreadable ? null : Land.mergedPaths(tree),
				print: line -> printed.push(line)
			});
			final status: Int = go();
			final firstLines: Int = printed.length;
			final againStatus: Int = shape.again == true ? go() : 0;
			{
				status: status,
				againStatus: againStatus,
				againOutput: printed.slice(firstLines).join('\n'),
				output: printed.join('\n'),
				flags: flags,
				base: base,
				builtFrom: builtFrom,
				builtTreeLeft: FileSystem.exists(builtTree),
				headBefore: headBefore,
				tallied: FileSystem.exists('$cache/landings'),
				builds: builds,
				merging: cmd('git -C $repo rev-parse -q --verify CHERRY_PICK_HEAD').run().ok
					|| cmd('git -C $repo rev-parse -q --verify MERGE_HEAD').run().ok,
				dirty: cmd('git -C $repo status --porcelain').run().out.trim(),
				merged: FileSystem.exists('$repo/b.txt'),
				moved: cmd('git -C $repo rev-parse HEAD').run().out.trim() != headBefore,
				parents: cmd('git -C $repo rev-list --parents -n 1 HEAD').run().out.trim().split(' ').length - 1,
				commits: Std.parseInt(cmd('git -C $repo rev-list --count HEAD').run().out.trim()) ?? -1,
				message: cmd('git -C $repo log -1 --format=%B').run().out.trim(),
				author: cmd('git -C $repo log -1 --format=%an').run().out.trim(),
				files: [for (path in shape.read ?? []) path => File.getContent('$repo/$path')],
				brief: FileSystem.exists('$logs/merge-brief.md') ? File.getContent('$logs/merge-brief.md') : ''
			};
		});
	}

	private static function write(repo: String, edits: Array<Edit>): Void {
		for (edit in edits) {
			makeDirectories(Path.directory('$repo/${edit.path}'));
			File.saveContent('$repo/${edit.path}', edit.content);
		}
	}

	private static function git(repo: String, words: Array<String>): Void {
		cmd('git -c user.name=land -c user.email=land@example.com -c commit.gpgsign=false -C $repo $words').run().check();
	}

	private static function makeDirectories(path: String): Void {
		js.Syntax.code("require('fs').mkdirSync({0}, { recursive: true })", path);
	}

	/**
	 * `main` with a base commit and the branch `batch/hxqb-S1` with the
	 * one commit `added` (a rename of `renameFrom`); `shape` adds more.
	 */
	private static function scaffold(repo: String, added: String, renameFrom: Null<String>, shape: Setup): Void {
		FileSystem.createDirectory(repo);
		git(repo, ['init', '-q', '-b', 'main']);
		File.saveContent('$repo/a.txt', 'a\n');
		if (renameFrom != null) {
			makeDirectories(Path.directory('$repo/$renameFrom'));
			File.saveContent('$repo/$renameFrom', 'moved\n');
		}
		if (shape.attributes != null) File.saveContent('$repo/.gitattributes', shape.attributes);
		write(repo, shape.base ?? []);
		git(repo, ['add', '.']);
		git(repo, ['commit', '-q', '-m', 'base']);
		git(repo, ['checkout', '-q', '-b', BRANCH]);
		makeDirectories(Path.directory('$repo/$added'));
		if (renameFrom == null)
			File.saveContent('$repo/$added', 'b\n');
		else
			git(repo, ['mv', renameFrom, added]);
		write(repo, shape.onSide ?? []);
		git(repo, ['add', '.']);
		git(repo, ['commit', '-q', '-m', shape.sideMessage ?? 'side']);
		for (edit in shape.moreCommits ?? []) {
			write(repo, [edit]);
			git(repo, ['add', '.']);
			git(repo, ['commit', '-q', '-m', 'more']);
		}
		git(repo, ['checkout', '-q', 'main']);
		if (shape.preLanded == true) git(repo, ['merge', '-q', '--ff-only', BRANCH]);
		if (shape.handPicked == true) {
			git(repo, ['commit', '-q', '--allow-empty', '-m', 'main moved']);
			git(repo, ['cherry-pick', BRANCH]);
		}
		if (shape.onMain == null) return;
		write(repo, shape.onMain);
		git(repo, ['add', '.']);
		git(repo, ['commit', '-q', '-m', 'main moved']);
	}

	/** `build`, after `during` — what the user does to the tree while the binaries are being built — has run in `repo`. */
	private static function interfere(during: Null<(repo:String) -> Void>, repo: String, build: () -> Outcome): Outcome {
		if (during != null) during(repo);
		return build();
	}

	/** The cache of a landing that asks for a battery holds the snapshot of `base`, unless the scenario is the cache lacking it. */
	private static function seedBase(battery: Null<Battery>, cache: String, base: String): Void {
		if (battery == null || battery.noSnapshot == true) return;
		makeDirectories(cache);
		File.saveContent('$cache/$base-suite.txt', '1 2\n');
	}

	/** The battery that makes the snapshot of `base` in `cache`, as the scenario has it: red, or leaving no snapshot at all. */
	private static function makeBase(battery: Null<Battery>, cache: String, base: String): Outcome {
		final left: Bool = battery?.baseFails != true;
		if (left) {
			makeDirectories(cache);
			File.saveContent('$cache/$base-suite.txt', '1 2\n');
		}
		return left && battery?.baseRed != true ? Passed : Failed('the battery is red');
	}

}

/** What a `Land.land` run over a scratch repository left behind. */
private typedef Landing = {
	var status: Int;
	var output: String;

	/** The flags of every battery the run started. */
	var flags: Array<Array<String>>;

	/**
	 * The commit `main` was at before the run and its snapshot key; when a battery made the snapshot, the commit of the tree
	 * it ran over and whether that tree outlived it.
	 */
	var headBefore: String;
	var base: String;
	var builtFrom: String;
	var builtTreeLeft: Bool;

	/** Whether the landings were counted. */
	var tallied: Bool;
	var builds: Int;
	var merging: Bool;
	var dirty: String;
	var merged: Bool;

	/** Whether `main` is at another commit than before the run. */
	var moved: Bool;

	/** The parents of the commit `main` ends at. */
	var parents: Int;

	/** The commits `main` ends with. */
	var commits: Int;

	/** The message and the author of the head commit. */
	var message: String;
	var author: String;

	/** The status and the output of a second landing of the same branch right after the first. */
	var againStatus: Int;
	var againOutput: String;

	/** The contents, after the run, of the paths the setup asked to read. */
	var files: Map<String, String>;

	/** The merge brief the run wrote, or empty. */
	var brief: String;
}

/** The battery a landing asks for: whether in full, and the landings the count already holds. */
private typedef Battery = {
	var full: Bool;
	var landed: Int;

	/** Whether the script is red. */
	@:optional var fails: Bool;

	/**
	 * Whether the cache lacks the snapshot of the commit landed onto; whether the battery that makes it is red but still
	 * leaves a snapshot, or leaves none.
	 */
	@:optional var noSnapshot: Bool;
	@:optional var baseRed: Bool;
	@:optional var baseFails: Bool;

	/** Whether the paths of the merge cannot be read. */
	@:optional var unreadable: Bool;
}

/** One file written whole. */
private typedef Edit = {
	var path: String;
	var content: String;
}

/** What a scratch repository holds beside the one commit of the branch. */
private typedef Setup = {
	/** The text of `.gitattributes`. */
	@:optional var attributes: String;

	/** Files in the base commit, and files the branch's commit writes beside its own. */
	@:optional var base: Array<Edit>;
	@:optional var onSide: Array<Edit>;

	/** One more commit on the branch per edit. */
	@:optional var moreCommits: Array<Edit>;

	/** One commit on `main` after the branch point. */
	@:optional var onMain: Array<Edit>;

	/** Whether `main` already holds the branch's patch as a commit of its own, made by hand, with no trailer. */
	@:optional var handPicked: Bool;

	/** Whether `main` already holds the branch's commit. */
	@:optional var preLanded: Bool;

	/** The message of the branch's commit, and the `-m` of the landing. */
	@:optional var sideMessage: String;
	@:optional var message: String;

	/** The trailers the landing marks its commit with beside `Slice`. */
	@:optional var trailers: Array<String>;

	/** The places the landing settles for the merge driver (`--resolve`). */
	@:optional var resolve: Array<String>;

	/** What the user does in the repository while the binaries are built, and whether the branch is landed a second time. */
	@:optional var during: (repo:String) -> Void;
	@:optional var again: Bool;

	/** The paths whose contents the run reports. */
	@:optional var read: Array<String>;
}

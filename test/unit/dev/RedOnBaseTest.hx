package unit.dev;

import dev.BatteryPlan;
import dev.RedOnBase;
import dev.Shard.Tally;
import devkit.Cmd.cmd;
import devkit.Summary.Outcome;
import devkit.TempDir;
import haxe.Exception;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

using StringTools;

/** `dev.RedOnBase`: whether a red row of a candidate is also red on the candidate's base, and how a row says so. */
@:nullSafety(Strict)
final class RedOnBaseTest extends Test {

	private static final TALLY: Tally = {
		tests: 12,
		assertions: 30,
		failures: 1,
		errors: 0
	};

	/** The classes of the failing tests are the part before the method, each once and in order. */
	@:pin('control')
	@:killer('M-REDONBASE-CLASS-IS-THE-TEST')
	@:killer('M-REDONBASE-CLASS-REPEATED')
	public function testTheFailingTestsReduceToTheirClasses(): Void {
		Assert.same(['unit.A', 'unit.B'], RedOnBase.classesOf(['unit.A.testOne', 'unit.B.testTwo', 'unit.A.testThree']));
		Assert.same([], RedOnBase.classesOf([]));
	}

	/** A class the base does not register is not re-run there: a test the candidate added cannot be red on the base. */
	@:pin('control')
	@:killer('M-REDONBASE-PRESENT-KEEPS-ALL')
	public function testOnlyTheClassesTheBaseRegistersAreRerun(): Void {
		Assert.same(['unit.A'], RedOnBase.present(['unit.A', 'unit.New'], 'unit.A\nunit.B\n'));
		Assert.same([], RedOnBase.present(['unit.New'], 'unit.A\n'));
	}

	/**
	 * A re-run red on every failing test of the candidate reads `yes`, a
	 * green one `no`, one that counted nothing or named nothing unknown.
	 */
	@:pin('control')
	@:killer('M-REDONBASE-SUITE-GREEN-NOT-READ')
	@:killer('M-REDONBASE-SUITE-EMPTY-TRUSTED')
	@:killer('M-REDONBASE-SUITE-UNNAMED-RED-TRUSTED')
	@:killer('M-REDONBASE-ALL-RED-READ-PARTLY')
	public function testARedRerunIsYesAGreenOneNoAnEmptyOneUnknown(): Void {
		final red: OnBase = RedOnBase.ofSuite(1, TALLY, ['unit.A.testOne', 'unit.B.testTwo'], ['unit.A.testOne']);
		Assert.same(OnBase.Red(['unit.A.testOne']), red);
		Assert.equals('red on base: yes (unit.A.testOne)', RedOnBase.note(red));
		final green: OnBase = RedOnBase.ofSuite(0, TALLY, [], ['unit.A.testOne']);
		Assert.same(OnBase.Green, green);
		Assert.equals('red on base: no', RedOnBase.note(green));
		final empty: OnBase = RedOnBase.ofSuite(1, null, [], ['unit.A.testOne']);
		Assert.same(OnBase.Unknown('the base re-run counted no tests'), empty);
		Assert.same(
			empty, RedOnBase.ofSuite(1, {
				tests: 0,
				assertions: 0,
				failures: 0,
				errors: 0
			}, [], ['unit.A.testOne'])
		);
		Assert.equals('red on base: unknown (the base re-run counted no tests)', RedOnBase.note(empty));
		final unnamed: OnBase = RedOnBase.ofSuite(1, TALLY, [], ['unit.A.testOne']);
		Assert.same(OnBase.Unknown('the base re-run was red but named no failing test'), unnamed);
	}

	/**
	 * Only some of the candidate's failing tests being red on the base reads `partly`, naming both sides: a failing test the base
	 * does not fail (another method, or a class the candidate added) is the candidate's own.
	 */
	@:pin('control')
	@:killer('M-REDONBASE-PARTLY-READ-YES')
	@:killer('M-REDONBASE-PARTLY-READ-NO')
	@:killer('M-REDONBASE-NONE-RED-READ-PARTLY')
	public function testSomeFailuresRedOnTheBaseReadPartly(): Void {
		final partly: OnBase = RedOnBase.ofSuite(1, TALLY, ['unit.A.testOne'], ['unit.A.testOne', 'unit.B.testTwo']);
		Assert.same(OnBase.Partly(['unit.A.testOne'], ['unit.B.testTwo']), partly);
		Assert.equals('red on base: partly (yes: unit.A.testOne; no: unit.B.testTwo)', RedOnBase.note(partly));
		Assert.same(OnBase.Green, RedOnBase.ofSuite(1, TALLY, ['unit.A.testNine'], ['unit.A.testOne']));
	}

	/** Kits compare by area: red on the base only where the candidate's own failing areas fail there too; no failing area is unknown. */
	@:pin('control')
	@:killer('M-REDONBASE-ALL-RED-READ-PARTLY')
	@:killer('M-REDONBASE-PARTLY-READ-YES')
	@:killer('M-REDONBASE-NONE-RED-READ-PARTLY')
	@:killer('M-REDONBASE-COMPARE-EMPTY-CANDIDATE')
	public function testKitsAreComparedAreaByArea(): Void {
		Assert.same(OnBase.Red(['ops']), RedOnBase.compare(['ops'], ['ops', 'lint']));
		Assert.same(OnBase.Green, RedOnBase.compare(['ops'], ['lint']));
		Assert.same(OnBase.Partly(['ops'], ['fmt']), RedOnBase.compare(['ops', 'fmt'], ['ops', 'lint']));
		Assert.same(OnBase.Unknown('the candidate names no failing item'), RedOnBase.compare([], ['lint']));
	}

	/** A long list of items is cut to the first few and counts the rest. */
	@:pin('guard')
	public function testTheNoteCutsALongList(): Void {
		Assert.equals('red on base: yes (a, b, c, d, e, … +2 more)', RedOnBase.note(OnBase.Red(['a', 'b', 'c', 'd', 'e', 'f', 'g'])));
	}

	/** A failed row gains what the base reads, in the same reason; a row that did not fail never asks the base. */
	@:pin('control')
	@:killer('M-REDONBASE-AFTER-DROPS-NOTE')
	@:killer('M-REDONBASE-AFTER-ASKS-ALWAYS')
	public function testOnlyAFailedRowIsAskedAboutTheBase(): Void {
		var asked: Int = 0;
		final rerun: () -> OnBase = () -> {
			asked++;
			return OnBase.Green;
		};
		Assert.same(
			Outcome.Failed('the suite is not green; red on base: no'), RedOnBase.after(Outcome.Failed('the suite is not green'), rerun)
		);
		Assert.equals(1, asked);
		Assert.same(Outcome.Passed, RedOnBase.after(Outcome.Passed, rerun));
		Assert.same(Outcome.Skipped('x'), RedOnBase.after(Outcome.Skipped('x'), rerun));
		Assert.equals(1, asked);
	}

	/** The re-run is made in a tree of the base commit that is gone afterwards, whatever the re-run did. */
	@:pin('control')
	@:killer('M-GATETREE-CHECKOUT-TREE-KEPT')
	@:killer('M-GATETREE-CHECKOUT-THROW-ESCAPES')
	public function testTheBaseTreeExistsOnlyWhileTheRerunRuns(): Void {
		TempDir.with(dir -> {
			final repo: String = committed(dir);
			final request: BaseRerun = requestOf(repo, base(repo));
			var tree: String = '';
			var seenFile: Bool = false;
			final answer: OnBase = RedOnBase.onBase(request, _ -> Outcome.Passed, checkout -> {
				tree = checkout;
				seenFile = FileSystem.exists('$checkout/tracked.txt');
				return OnBase.Red(['unit.A']);
			});
			Assert.same(OnBase.Red(['unit.A']), answer);
			Assert.isTrue(seenFile);
			Assert.isFalse(FileSystem.exists(tree));
			Assert.isFalse(cmd('git -C $repo worktree list --porcelain').text().contains(tree), 'the tree is still registered with git');
			final thrown: OnBase = RedOnBase.onBase(request, _ -> Outcome.Passed, checkout -> {
				tree = checkout;
				throw new Exception('boom');
			});
			Assert.same(OnBase.Unknown('boom'), thrown);
			Assert.isFalse(FileSystem.exists(tree));
			Assert.isFalse(cmd('git -C $repo worktree list --porcelain').text().contains(tree), 'the tree is still registered with git');
		});
	}

	/** A base that does not build is never run, and a run that compares with no base asks nothing of git. */
	@:pin('control')
	@:killer('M-REDONBASE-UNBUILT-BASE-RUN')
	@:killer('M-REDONBASE-NO-BASE-READ-GREEN')
	public function testABaseThatDoesNotBuildOrIsMissingReadsUnknown(): Void {
		TempDir.with(dir -> {
			final repo: String = committed(dir);
			var ran: Bool = false;
			final unbuilt: OnBase = RedOnBase.onBase(requestOf(repo, base(repo)), _ -> Outcome.Failed('no haxe'), _ -> {
				ran = true;
				return OnBase.Green;
			});
			Assert.same(OnBase.Unknown('the base did not build: no haxe'), unbuilt);
			Assert.isFalse(ran);
			final none: OnBase = RedOnBase.onBase(requestOf(repo, null), _ -> Outcome.Passed, _ -> {
				ran = true;
				return OnBase.Green;
			});
			Assert.same(OnBase.Unknown('the run compares with no base'), none);
			Assert.isFalse(ran);
		});
	}

	/** A battery's re-run keeps its tree and transcript among the run's work files, named by the row. */
	@:pin('guard')
	public function testTheRequestOfARowLivesInTheRunsWorkDirectory(): Void {
		final plan: BatteryPlan = {
			repo: '/r',
			work: '/w',
			cache: '/c',
			head: 'h',
			base: 'b',
			shards: 3,
			quick: false,
			snapshot: false,
			allowBlast: false,
			allow: [],
			run: '1',
			ownLease: false
		};
		final made: BaseRerun = RedOnBase.requestFor(plan, 'suite', Unpooled);
		Assert.equals('/r', made.repo);
		Assert.equals('b', made.base);
		Assert.equals('/w/red-on-base-suite.log', made.log);
		Assert.equals(3, made.shards);
	}

	private static function requestOf(repo: String, base: Null<String>): BaseRerun {
		return {
			repo: repo,
			base: base,
			log: 'build.log',
			shards: 1,
			mode: Unpooled
		};
	}

	/** A repository in `dir` holding one commit with one tracked file. */
	private static function committed(dir: TempDir): String {
		final repo: String = dir.file('repo');
		FileSystem.createDirectory(repo);
		File.saveContent('$repo/tracked.txt', 'x\n');
		cmd('git -C $repo init -q').check();
		cmd('git -C $repo add tracked.txt').check();
		cmd('git -C $repo -c user.name=t -c user.email=t@t commit -q -m one').check();
		return repo;
	}

	private static function base(repo: String): String {
		return cmd('git -C $repo rev-parse HEAD').text().trim();
	}

}

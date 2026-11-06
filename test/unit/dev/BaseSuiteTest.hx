package unit.dev;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JsonFormat;
import dev.BaseEngine;
import dev.BaseSuite;
import dev.BaselineWriter;
import dev.GateReuse;
import dev.GateTree;
import dev.Shard.Tally;
import devkit.Cmd.cmd;
import devkit.Lease.LeaseMode;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/** `dev.BaseSuite`: what a kept reading of the base suite stands for, and when it is read again instead. */
@:nullSafety(Strict)
final class BaseSuiteTest extends Test {

	/** The stamp follows the base commit, the corpus tree's state and the compiler, and not a trailing newline. */
	@:pin('guard')
	public function testTheStampFollowsTheBaseTheCorpusAndTheCompiler(): Void {
		final stamp: String = BaseSuite.stampOf('abc', 'fork s1', 'haxe 4');
		Assert.equals(stamp, BaseSuite.stampOf('abc\n', 'fork s1', 'haxe 4'));
		Assert.notEquals(stamp, BaseSuite.stampOf('abd', 'fork s1', 'haxe 4'));
		Assert.notEquals(stamp, BaseSuite.stampOf('abc', 'fork s2', 'haxe 4'));
		Assert.notEquals(stamp, BaseSuite.stampOf('abc', '', 'haxe 4'));
		Assert.notEquals(stamp, BaseSuite.stampOf('abc', 'fork s1', 'haxe 5'));
	}

	/** A record read back under its own stamp gives the counts and the sweep it was made with; under another stamp, nothing. */
	@:pin('guard')
	public function testARecordIsReadBackOnlyUnderItsStamp(): Void {
		TempDir.with(dir -> {
			final sweep: String = dir.file('sweep-base.json');
			File.saveContent(sweep, '{}');
			final text: String = BaseSuite.encode('s1', { tests: 7, assertions: 9, sweep: sweep });
			final got: Null<BaseReading> = BaseSuite.decode('s1', text, sweep);
			Assert.notNull(got);
			Assert.equals(7, got?.tests);
			Assert.equals(9, got?.assertions);
			Assert.equals(sweep, got?.sweep);
			Assert.isNull(BaseSuite.decode('s2', text, sweep));
		});
	}

	/** A record that names a sweep reads as nothing once the snapshot is gone, and one that names none does not need it. */
	@:pin('guard')
	public function testARecordWhoseSweepIsGoneIsNotUsed(): Void {
		TempDir.with(dir -> {
			final sweep: String = Path.join([dir.file('logs'), 'sweep-base.json']);
			Assert.isNull(BaseSuite.decode('s1', BaseSuite.encode('s1', { tests: 1, assertions: 2, sweep: sweep }), sweep));
			final plain: Null<BaseReading> =
				BaseSuite.decode('s1', BaseSuite.encode('s1', { tests: 1, assertions: 2, sweep: null }), sweep);
			Assert.notNull(plain);
			Assert.isNull(plain?.sweep);
		});
	}

	/** A damaged record is no reading. */
	@:pin('guard')
	public function testADamagedRecordIsNoReading(): Void {
		Assert.isNull(BaseSuite.decode('s1', '', 'x'));
		Assert.isNull(BaseSuite.decode('s1', 's1\nmany\n2\nno sweep\n', 'x'));
		Assert.isNull(BaseSuite.decode('s1', 's1\n1\n', 'x'));
	}

	/** The base checkout is built with the engine its tests spawn beside the runner, not the runner alone. */
	@:pin('control')
	@:killer('M-BASESUITE-ENGINE-NOT-BUILT')
	public function testTheBaseCheckoutBuildsTheEngineBesideTheRunner(): Void {
		final builds: Array<String> = BaseSuite.builds().map(words -> words.join(' '));
		Assert.contains('bin/apq-js.hxml', builds);
		Assert.contains('test-js.hxml', builds);
	}

	/**
	 * The base suite runs with the engine variable on its own checkout's engine, and the gate's value is back afterwards, even
	 * when the run throws.
	 */
	@:pin('control')
	@:killer('M-BASESUITE-ENGINE-UNPINNED')
	@:killer('M-BASESUITE-ENGINE-LEAKS')
	public function testTheBaseSuiteRunsTheEngineOfItsOwnCheckout(): Void {
		final before: Null<String> = Sys.getEnv(GateTree.ENGINE_VAR);
		CliFixture.always(() -> BaseSuite.setEngine(before), () -> {
			BaseSuite.setEngine('/tip/bin/apq.js');
			var seen: String = '';
			final status: Int = BaseSuite.withEngine('/base', () -> {
				seen = Sys.getEnv(GateTree.ENGINE_VAR) ?? '';
				return 3;
			});
			Assert.equals(3, status);
			Assert.equals('/base/bin/apq.js', seen);
			Assert.equals('/tip/bin/apq.js', Sys.getEnv(GateTree.ENGINE_VAR));
			Assert.raises(() -> BaseSuite.withEngine('/base', () -> throw 'red'), String);
			Assert.equals('/tip/bin/apq.js', Sys.getEnv(GateTree.ENGINE_VAR));
		});
	}

	/** An impact gate, or one whose own suite is red, reads no base suite: no record, no base checkout, no build. */
	@:pin('control')
	@:killer('M-BASESUITE-IMPACT-READS-BASE')
	@:killer('M-BASESUITE-RED-GATE-READS-BASE')
	public function testAnImpactOrRedGateRunsNoBaseSuite(): Void {
		TempDir.with(dir -> {
			final gate: GateTree = gateOf(dir);
			final sum: Tally = {
				tests: 107,
				assertions: 210,
				failures: 0,
				errors: 0
			};
			Assert.equals('', BaseSuite.deltaNote(gate, Unpooled, sum, 0, ['unit.dev.SomeTest']));
			Assert.equals('', BaseSuite.deltaNote(gate, Unpooled, sum, 1, null));
			Assert.isFalse(FileSystem.exists(gate.log(BaseSuite.FILE)));
			Assert.isFalse(FileSystem.exists(gate.log('suite-base-build.log')));
		});
	}

	/** A green whole-suite gate with a base reading in its logs prints its counts beside the base's. */
	@:pin('control')
	@:killer('M-BASESUITE-DELTA-DROPPED')
	public function testAWholeGreenGatePrintsItsDeltaAgainstTheKeptBaseReading(): Void {
		TempDir.with(dir -> {
			final gate: GateTree = gateOf(dir);
			final stamp: String = BaseSuite.stampOf(gate.base, GateReuse.forkState(), BaseEngine.toolchain());
			File.saveContent(gate.log(BaseSuite.FILE), BaseSuite.encode(stamp, { tests: 100, assertions: 200, sweep: null }));
			final sum: Tally = {
				tests: 107,
				assertions: 190,
				failures: 0,
				errors: 0
			};
			Assert.equals(' (+7 / -10)', BaseSuite.deltaNote(gate, Unpooled, sum, 0, null));
		});
	}

	/**
	 * A whole-suite gate announces the base branch only while the base suite is unread: an impact gate, a gate with no baseline
	 * and a gate whose base reading is kept start none, and a kept reading lifts the announcement of an earlier plan.
	 */
	@:pin('guard')
	public function testAWholeGateAnnouncesTheBaseBranchOnlyWhileTheBaseIsUnread(): Void {
		TempDir.with(dir -> withCache(dir.file('cache'), () -> {
			final gate: GateTree = gateOf(dir);
			Assert.isFalse(BaseSuite.plan(gate, false), 'an impact gate');
			Assert.isFalse(BaseSuite.pending(gate));
			Assert.isTrue(BaseSuite.plan(gate, true));
			Assert.isTrue(BaseSuite.pending(gate));
			File.saveContent(gate.log(BaseSuite.FILE), BaseSuite.encode(stampOf(gate), { tests: 1, assertions: 2, sweep: null }));
			Assert.isFalse(BaseSuite.plan(gate, true), 'a kept reading');
			Assert.isFalse(BaseSuite.pending(gate), 'the earlier plan is lifted');
			final other: GateTree = gateOf(dir, '2', false);
			Assert.isFalse(BaseSuite.plan(other, true), 'no baseline to compare with');
		}));
	}

	/**
	 * A second gate on the same base, in another worktree, reads what the first measured from the cache the worktrees share: it
	 * announces no branch, runs no base build, and has the counts and the sweep.
	 */
	@:pin('guard')
	public function testASecondGateOnTheSameBaseRunsNoBaseSuite(): Void {
		TempDir.with(dir -> withCache(dir.file('cache'), () -> {
			final first: GateTree = gateOf(dir, '1');
			final second: GateTree = gateOf(dir, '2');
			final stamp: String = stampOf(second);
			final sweep: String = first.log(GateTree.SWEEP_BASE);
			File.saveContent(sweep, '{"swept":1}');
			final reading: BaseReading = { tests: 100, assertions: 200, sweep: sweep };
			File.saveContent(first.log(BaseSuite.FILE), BaseSuite.encode(stamp, reading));
			BaseSuite.store(BaseSuite.defaultCache(), stamp, first, reading);
			Assert.isFalse(BaseSuite.plan(second, true));
			switch BaseSuite.read(second, Unpooled) {
				case Read(got):
					Assert.equals(100, got.tests);
					Assert.equals(200, got.assertions);
					Assert.equals('{"swept":1}', File.getContent(got.sweep ?? ''));
				case Unread(why):
					Assert.fail(why);
			}
			Assert.isFalse(FileSystem.exists(second.log('suite-base-build.log')), 'no base checkout was built');
		}));
	}

	/**
	 * A row that asks while the base branch is still running waits for it and takes what it leaves, the counts or the reason there
	 * are none; it never measures the base suite beside the branch. After a failed branch the next row is told why, not left to measure.
	 */
	@:pin('guard')
	public function testARowWaitsForTheBaseBranchInsteadOfMeasuring(): Void {
		TempDir.with(dir -> withCache(dir.file('cache'), () -> {
			final gate: GateTree = gateOf(dir);
			final record: String = dir.file('record');
			File.saveContent(record, BaseSuite.encode(stampOf(gate), { tests: 100, assertions: 200, sweep: null }));
			Assert.isTrue(BaseSuite.plan(gate, true));
			later('sleep 1 && cp $record ${gate.log(BaseSuite.FILE)} && rm ${gate.log(BaseSuite.PENDING)}');
			Assert.equals(
				100, switch BaseSuite.read(gate, Unpooled) {
					case Read(got): got.tests;
					case Unread(_): -1;
				}
			);
			FileSystem.deleteFile(gate.log(BaseSuite.FILE));
			Assert.isTrue(BaseSuite.plan(gate, true));
			later('sleep 1 && printf "no build" > ${gate.log(BaseSuite.UNREAD)} && rm ${gate.log(BaseSuite.PENDING)}');
			Assert.same(
				'no build', switch BaseSuite.read(gate, Unpooled) {
					case Unread(why): why;
					case Read(_): 'read';
				}
			);
			Assert.same(
				'no build', switch BaseSuite.read(gate, Unpooled) {
					case Unread(why): why;
					case Read(_): 'read';
				},
				'a later row is told the same'
			);
			Assert.isFalse(FileSystem.exists(gate.log('suite-base-build.log')), 'no base checkout was built');
		}));
	}

	/**
	 * The base branch that cannot read the base suite (no test build in the base checkout) fails its row, leaves why in the
	 * logs before it lifts its announcement, and a row asking afterwards is told the same why without a second attempt; so does
	 * a branch that throws.
	 */
	@:pin('guard')
	public function testAFailedBaseBranchLeavesItsWhyBeforeLiftingItsAnnouncement(): Void {
		TempDir.with(dir -> withCache(dir.file('cache'), () -> {
			final gate: GateTree = gateOf(dir);
			Assert.isTrue(BaseSuite.plan(gate, true));
			final why: String = switch BaseSuite.branch(gate, Unpooled) {
				case Failed(reason): reason;
				case _: '';
			};
			Assert.notEquals('', why);
			Assert.equals(why, File.getContent(gate.log(BaseSuite.UNREAD)));
			Assert.isFalse(BaseSuite.pending(gate));
			FileSystem.deleteFile(gate.log('suite-base-build.log'));
			Assert.equals(
				why, switch BaseSuite.read(gate, Unpooled) {
					case Unread(again): again;
					case Read(_): '';
				}
			);
			Assert.isFalse(FileSystem.exists(gate.log('suite-base-build.log')), 'the base was not built a second time');
		}));
		TempDir.with(dir -> withCache(dir.file('cache'), () -> {
			final gate: GateTree = gateOf(dir);
			Assert.isTrue(BaseSuite.plan(gate, true));
			FileSystem.createDirectory(gate.log(BaseSuite.FILE));
			Assert.isTrue(BaseSuite.branch(gate, Unpooled).match(Failed(_)));
			Assert.isTrue(FileSystem.exists(gate.log(BaseSuite.UNREAD)));
			Assert.isFalse(BaseSuite.pending(gate));
		}));
	}

	/** A git tree with one commit and the baseline record of it in a logs directory beside, as a gate over it reads them. */
	private static function gateOf(dir: TempDir, name: String = '', withBaseline: Bool = true): GateTree {
		final tree: String = dir.file('tree$name');
		final logs: String = dir.file('logs$name');
		FileSystem.createDirectory(tree);
		FileSystem.createDirectory(logs);
		File.saveContent(Path.join([tree, 'keep']), tree);
		final git: Array<String> = ['-c', 'user.name=t', '-c', 'user.email=t@t'];
		cmd('git init -q -b main').at(tree).check();
		cmd('git add -A').at(tree).check();
		cmd('git $git commit -q -m base').at(tree).check();
		final base: String = cmd('git rev-parse HEAD').at(tree).check().out.trim();
		if (withBaseline) File.saveContent(
			Path.join([logs, GateTree.BASELINE_FILE]), BaselineWriter.write({
				base: base,
				lists: JObject([]),
				infra: [],
				frozen: []
			}, JsonFormat.instance.compactWriteOptions)
		);
		return new GateTree({
			tree: tree,
			logs: logs,
			baseline: false,
			frozen: [],
			infra: [],
			arms: [],
			allow: [],
			allowArms: [],
			noArms: false,
			threads: null,
			run: 'r'
		});
	}

	/** `body` with the cache shared by every gate pointed at `cache`; the environment is restored afterwards, even when `body` throws. */
	private static function withCache(cache: String, body: () -> Void): Void {
		final saved: Null<String> = Sys.getEnv(BaseSuite.CACHE_VAR);
		final set: Null<String> -> Void = value -> {
			if (value == null)
				js.Syntax.code('delete process.env[{0}]', BaseSuite.CACHE_VAR)
			else
				Sys.putEnv(BaseSuite.CACHE_VAR, value);
		};
		CliFixture.always(() -> set(saved), () -> {
			set(cache);
			body();
		});
	}

	/** The stamp a reading of `gate`'s base is kept under. */
	private static function stampOf(gate: GateTree): String {
		return BaseSuite.stampOf(gate.base, GateReuse.forkState(), BaseEngine.toolchain());
	}

	/** `command` started in the background, to end after the test's own wait has begun: what another process does to the gate's logs. */
	private static function later(command: String): Void {
		js.Syntax.code("require('child_process').exec({0})", command);
	}

}

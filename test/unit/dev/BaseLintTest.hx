package unit.dev;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JsonFormat;
import dev.BaseBranch.BaseGot;
import dev.BaseEngine;
import dev.BaseLint;
import dev.BaselineWarm;
import dev.BaselineWriter;
import dev.GateLint;
import dev.GateTree;
import devkit.Cmd.cmd;
import devkit.Command;
import devkit.Result;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/** `dev.BaseLint`: when a gate lints the base for INFRA gate 4, and when it takes the report another run left instead. */
@:nullSafety(Strict)
final class BaseLintTest extends Test {

	private static inline final POLL_SECONDS: Float = 0.05;

	/**
	 * A gate announces the base lint branch only when its `infra4` row will compare and the report is not kept: a gate that moved
	 * no rule code, or whose baseline names no infra tree, starts none, and a kept report lifts the announcement of an earlier plan.
	 */
	@:pin('control')
	@:killer('M-BASE-LINT-NEEDED-ALWAYS')
	public function testAGateAnnouncesTheBaseLintOnlyWhenInfra4WillCompare(): Void {
		TempDir.with(dir -> withCache(dir.file('cache'), () -> {
			Assert.isFalse(BaseLint.plan(gateOf(dir, 'plain', false, true)), 'no rule code moved');
			Assert.isFalse(BaseLint.plan(gateOf(dir, 'bare', true, false)), 'no infra tree to compare');
			final gate: GateTree = gateOf(dir);
			Assert.isTrue(BaseLint.plan(gate));
			Assert.isTrue(FileSystem.exists(gate.log(BaseLint.PENDING)));
			File.saveContent(gate.log(BaseLint.FILE), '[]');
			File.saveContent(gate.log(BaseLint.STAMP), stampOf(gate));
			Assert.isFalse(BaseLint.plan(gate), 'a kept report');
			Assert.isFalse(FileSystem.exists(gate.log(BaseLint.PENDING)), 'the earlier plan is lifted');
		}));
	}

	/**
	 * A second gate on the same base, in another worktree, takes the report the first kept in the cache the worktrees share: it
	 * announces no branch and its read lints nothing.
	 */
	@:pin('control')
	@:killer('M-BASE-LINT-KEPT-BLIND')
	public function testASecondGateOnTheSameBaseLintsNoBase(): Void {
		TempDir.with(dir -> withCache(dir.file('cache'), () -> {
			final first: GateTree = gateOf(dir, '1');
			final second: GateTree = gateOf(dir, '2');
			final printed: Result = Command.of(['printf', '[]']).run();
			Assert.isNull(BaseLint.keep(printed, stampOf(second), first.log(BaseLint.FILE), BaseLint.defaultCache()));
			Assert.isFalse(BaseLint.plan(second));
			switch BaseLint.read(second) {
				case Got(report):
					Assert.equals(second.log(BaseLint.FILE), report);
					Assert.equals('[]', File.getContent(report));
				case NotGot(why):
					Assert.fail(why);
			}
			Assert.isFalse(FileSystem.exists(second.log('lint-base.err')), 'the base was not linted');
		}));
	}

	/**
	 * A row that asks while the base lint branch runs waits for it and takes what it leaves, the report or why there is none; it
	 * never lints the base beside the branch, and a later row is told the same why.
	 */
	@:pin('control')
	@:killer('M-BASE-BRANCH-READ-MEASURES-BESIDE')
	public function testARowWaitsForTheBaseLintBranchInsteadOfLinting(): Void {
		TempDir.with(dir -> withCache(dir.file('cache'), () -> {
			final gate: GateTree = gateOf(dir);
			final report: String = dir.file('report');
			final stamp: String = dir.file('stamp');
			File.saveContent(report, '[]');
			File.saveContent(stamp, stampOf(gate));
			Assert.isTrue(BaseLint.plan(gate));
			later(
				'sleep 1 && cp $report ${gate.log(BaseLint.FILE)} && cp $stamp ${gate.log(BaseLint.STAMP)} && rm '
				+ gate.log(BaseLint.PENDING)
			);
			Assert.equals(
				'[]', switch BaseLint.read(gate) {
					case Got(file): File.getContent(file);
					case NotGot(why): why;
				}
			);
			FileSystem.deleteFile(gate.log(BaseLint.STAMP));
			Assert.isTrue(BaseLint.plan(gate));
			later('sleep 1 && printf "no engine" > ${gate.log(BaseLint.UNREAD)} && rm ${gate.log(BaseLint.PENDING)}');
			for (_ in 0...2) Assert.equals(
				'no engine', switch BaseLint.read(gate) {
					case NotGot(why): why;
					case Got(_): 'read';
				}
			);
			Assert.isFalse(FileSystem.exists(gate.log('lint-base.err')), 'the base was not linted');
		}));
	}

	/**
	 * The `infra4` row compares with the report the base lint branch leaves: while the branch runs it waits, and a branch that
	 * left none makes the row `not run` with its why, not a lint of the base of its own.
	 */
	@:pin('control')
	@:killer('M-BASE-BRANCH-READ-MEASURES-BESIDE')
	public function testInfra4WaitsForTheBaseLintBranch(): Void {
		TempDir.with(dir -> withCache(dir.file('cache'), () -> {
			final gate: GateTree = gateOf(dir);
			for (hxml in ['bin/apq-js-common.hxml', 'bin/apq-js.hxml']) {
				FileSystem.createDirectory(Path.join([gate.tree, 'bin']));
				File.saveContent(Path.join([gate.tree, hxml]), '');
			}
			cmd('git add -A').at(gate.tree).check();
			cmd('git -c user.name=t -c user.email=t@t commit -q -m engine').at(gate.tree).check();
			Assert.isTrue(BaseLint.plan(gate));
			later('sleep 1 && printf "no engine" > ${gate.log(BaseLint.UNREAD)} && rm ${gate.log(BaseLint.PENDING)}');
			switch new GateLint(gate).infraOutcome() {
				case NotRun(why):
					Assert.stringContains('no engine', why);
				case other:
					Assert.fail('$other');
			}
		}));
	}

	/**
	 * The branch that cannot lint the base (the base builds no engine) fails its row and leaves why in the logs before it lifts its
	 * announcement; a row asking afterwards is told the same why without a second attempt.
	 */
	@:pin('control')
	@:killer('M-BASE-BRANCH-SETTLE-FORGETS-WHY')
	public function testAFailedBaseLintBranchLeavesItsWhyBeforeLiftingItsAnnouncement(): Void {
		TempDir.with(dir -> withCache(dir.file('cache'), () -> {
			final gate: GateTree = gateOf(dir);
			Assert.isTrue(BaseLint.plan(gate));
			final why: String = switch BaseLint.branch(gate) {
				case Failed(reason): reason;
				case _: '';
			};
			Assert.stringContains('apq-js-common.hxml', why);
			Assert.equals(why, File.getContent(gate.log(BaseLint.UNREAD)));
			Assert.isFalse(FileSystem.exists(gate.log(BaseLint.PENDING)));
			Assert.equals(
				why, switch BaseLint.read(gate) {
					case NotGot(again): again;
					case Got(_): '';
				}
			);
		}));
	}

	/** A lint that printed no report keeps nothing: neither in the logs nor in the cache. */
	@:pin('guard')
	public function testALintThatPrintedNoReportKeepsNothing(): Void {
		TempDir.with(dir -> {
			final cache: String = dir.file('cache');
			final report: String = dir.file('lint-base.json');
			Assert.notNull(BaseLint.keep(cmd('echo oops').run(), 's', report, cache));
			Assert.isFalse(FileSystem.exists(report));
			Assert.isFalse(BaseLint.restore(cache, 's', dir.path));
		});
	}

	/**
	 * The report a land's warm keeps for the landed commit is the one a rule-code gate based on that commit takes: the gate
	 * announces no base lint branch and reads the warm's report from the cache the two share.
	 */
	@:pin('control')
	@:killer('M-WARM-BASE-LINT-STAMP-OFF')
	public function testTheWarmsReportIsTheOneAGateOnTheLandedCommitTakes(): Void {
		TempDir.with(dir -> withCache(dir.file('cache'), () -> {
			final gate: GateTree = gateOf(dir);
			final landed: String = dir.file('landed');
			cmd('git -C ${gate.tree} worktree add -q --detach $landed ${gate.base}').check();
			FileSystem.createDirectory(Path.join([landed, 'bin']));
			File.saveContent(Path.join([landed, 'bin/hxq']), "echo '[]'\n");
			File.saveContent(Path.join([landed, 'bin/apq.js']), '');
			final work: String = dir.file('work');
			FileSystem.createDirectory(work);
			final warming: Warming = BaselineWarm.baseLint(landed, work);
			while (warming.running()) Sys.sleep(POLL_SECONDS);
			Assert.isTrue(warming.ended().match(Passed));
			Assert.isFalse(BaseLint.plan(gate), 'the warm kept the report');
			switch BaseLint.read(gate) {
				case Got(report):
					Assert.equals('[]', File.getContent(report).trim());
				case NotGot(why):
					Assert.fail(why);
			}
		}));
	}

	/**
	 * A git tree whose slice commit touches rule code when `ruleCode`, and the baseline record of its base in a logs directory
	 * beside, naming an infra tree when `infra`, as a gate over it reads them.
	 */
	private static function gateOf(dir: TempDir, name: String = '', ruleCode: Bool = true, infra: Bool = true): GateTree {
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
		if (ruleCode) {
			FileSystem.createDirectory(Path.join([tree, 'src/anyparse/check']));
			File.saveContent(Path.join([tree, 'src/anyparse/check/Rule.hx']), 'class Rule {}\n');
			cmd('git add -A').at(tree).check();
			cmd('git $git commit -q -m slice').at(tree).check();
		}
		File.saveContent(
			Path.join([logs, GateTree.BASELINE_FILE]), BaselineWriter.write({
				base: base,
				lists: JObject([]),
				infra: infra ? [{ tree: dir.file('infra'), snapshot: dir.file('infra.json') }] : [],
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
		final saved: Null<String> = Sys.getEnv(BaseLint.CACHE_VAR);
		final set: Null<String> -> Void = value -> {
			if (value == null)
				js.Syntax.code('delete process.env[{0}]', BaseLint.CACHE_VAR)
			else
				Sys.putEnv(BaseLint.CACHE_VAR, value);
		};
		CliFixture.always(() -> set(saved), () -> {
			set(cache);
			body();
		});
	}

	/** The stamp a report of `gate`'s base is kept under. */
	private static function stampOf(gate: GateTree): String {
		return BaseLint.stampOf(gate.base, BaseEngine.toolchain());
	}

	/** `command` started in the background, to end after the test's own wait has begun: what another process does to the gate's logs. */
	private static function later(command: String): Void {
		js.Syntax.code("require('child_process').exec({0})", command);
	}

}

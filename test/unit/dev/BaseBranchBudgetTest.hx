package unit.dev;

import dev.BaseBranch;
import dev.BranchWatch;
import dev.GateTree;
import devkit.Cmd.cmd;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * `dev.BaseBranch.read`: the time a row gives a base branch is the branch's own work, counted from the moment its pool lease
 * is granted (it rewrites its progress file then), under a ceiling on the whole wait.
 */
@:nullSafety(Strict)
final class BaseBranchBudgetTest extends Test {

	private static inline final IDLE_MS: Int = 2000;
	private static inline final ROW: String = 'budget-row';

	/** A branch that waits for its lease longer than the row's budget and then settles inside it is read, not cut. */
	@:pin('control')
	@:killer('M-BASE-BRANCH-BUDGET-COUNTS-LEASE-WAIT')
	public function testALeaseWaitPastTheBudgetIsNotTheRowsWork(): Void {
		TempDir.with(dir -> withBudget(() -> {
			final gate: GateTree = gateOf(dir);
			final branch: BaseBranch = branchOf();
			branch.announce(gate);
			later('sleep 2.5 && ${grant(gate)} && sleep 0.5 && ${settle(gate, branch)}');
			Assert.equals('read', outcome(branch, gate));
		}));
	}

	/** A branch whose own work, once granted, exceeds the budget is still no reading. */
	@:pin('control')
	@:killer('M-BASE-BRANCH-BUDGET-IGNORES-GRANT')
	public function testAGrantedBranchOverItsBudgetIsNotRead(): Void {
		TempDir.with(dir -> withBudget(() -> {
			final gate: GateTree = gateOf(dir);
			final branch: BaseBranch = branchOf();
			branch.announce(gate);
			later('sleep 0.2 && ${grant(gate)} && sleep 3.5 && ${settle(gate, branch)}');
			Assert.stringContains('over', outcome(branch, gate));
		}));
	}

	/** A branch never granted ends the wait at the ceiling: a dead pool does not hold the row for ever. */
	@:pin('control')
	@:killer('M-BASE-BRANCH-CEILING-LOOSE')
	public function testAnUngrantedBranchEndsTheWaitAtTheCeiling(): Void {
		TempDir.with(dir -> withBudget(() -> {
			final gate: GateTree = gateOf(dir);
			final branch: BaseBranch = branchOf();
			branch.announce(gate);
			later('sleep 4.6 && ${settle(gate, branch)}');
			Assert.stringContains('over', outcome(branch, gate));
		}));
	}

	/** An announcement forgets the progress an earlier run left, so a lease not yet granted is never taken for granted. */
	@:pin('control')
	@:killer('M-BASE-BRANCH-ANNOUNCE-KEEPS-OLD-GRANT')
	public function testAnAnnouncementForgetsAnEarlierRunsGrant(): Void {
		TempDir.with(dir -> {
			final gate: GateTree = gateOf(dir);
			final branch: BaseBranch = branchOf();
			FileSystem.createDirectory(Path.directory(gate.branchProgress(ROW)));
			File.saveContent(gate.branchProgress(ROW), ROW);
			branch.announce(gate);
			Assert.isFalse(FileSystem.exists(gate.branchProgress(ROW)));
		});
	}

	private static function outcome(branch: BaseBranch, gate: GateTree): String {
		return switch branch.read(gate, () -> FileSystem.exists(gate.log('reading')) ? 'x' : null, () -> 'measured', 'over the budget') {
			case Got(_): 'read';
			case NotGot(why): why;
		};
	}

	private static function branchOf(): BaseBranch {
		return new BaseBranch(ROW, 'budget.pending', 'budget.unread', 'BASE_BRANCH_BUDGET_CACHE', 'base-branch-budget');
	}

	/** The command of a branch granted its lease: the progress file the branch process rewrites as it starts its row. */
	private static function grant(gate: GateTree): String {
		return 'mkdir -p ${Path.directory(gate.branchProgress(ROW))} && printf $ROW > ${gate.branchProgress(ROW)}';
	}

	/** The command of a branch that leaves its reading and lifts its announcement. */
	private static function settle(gate: GateTree, branch: BaseBranch): String {
		return 'printf x > ${gate.log('reading')} && rm ${gate.log(branch.pendingFile)}';
	}

	private static function gateOf(dir: TempDir): GateTree {
		final tree: String = dir.file('tree');
		final logs: String = dir.file('logs');
		FileSystem.createDirectory(tree);
		FileSystem.createDirectory(logs);
		File.saveContent(Path.join([tree, 'keep']), tree);
		cmd('git init -q -b main').at(tree).check();
		cmd('git add -A').at(tree).check();
		cmd('git -c user.name=t -c user.email=t@t commit -q -m base').at(tree).check();
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

	/** `body` with every row limit set to `IDLE_MS`; the environment is restored afterwards, even when `body` throws. */
	private static function withBudget(body: () -> Void): Void {
		final saved: Null<String> = Sys.getEnv(BranchWatch.IDLE_VAR);
		CliFixture.always(() -> {
			if (saved == null)
				js.Syntax.code('delete process.env[{0}]', BranchWatch.IDLE_VAR)
			else
				Sys.putEnv(BranchWatch.IDLE_VAR, saved);
		}, () -> {
			Sys.putEnv(BranchWatch.IDLE_VAR, '$IDLE_MS');
			body();
		});
	}

	/** `command` started in the background, to end after the test's own wait has begun: what another process does to the gate's logs. */
	private static function later(command: String): Void {
		js.Syntax.code("require('child_process').exec({0})", command);
	}

}

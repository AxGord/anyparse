package unit.dev;

import dev.GateRecord;
import dev.GateReuse;
import devkit.Cmd.cmd;
import devkit.Summary.Outcome;
import devkit.Summary.Step;
import devkit.TempDir;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `GateReuse`: a land takes a gate's rows over only for the very tree the gate judged, only rows the gate passed, never from
 * a failed gate, and only from the gate's logs beside the worktree that holds the branch.
 */
@:nullSafety(Strict)
final class GateReuseTest extends Test {

	private static inline final BRANCH: String = 'batch/hxqb-S1';

	@:pin('control')
	@:killer('M-GATE-REUSE-NOTHING-TAKEN')
	public function testALandOfTheGatedTreeTakesOverEveryRowTheGateStandsFor(): Void {
		final trees: Array<String> = landed(false);
		Assert.equals(trees[0], trees[1], 'a slice cherry-picked onto the main it was gated on is the tree the gate judged');
		final taken: Array<String> = GateReuse.rows(passing(trees[0]), facts(trees[1]));
		Assert.same(['suite', 'corpus', 'jvm probe', 'kit probes'], taken);
		Assert.equals(
			'battery: reused gate ${trees[0].substr(0, 9)} for suite, corpus, jvm probe, kit probes',
			GateReuse.report(passing(trees[0]), facts(trees[1]), taken)
		);
	}

	@:pin('control')
	@:killer('M-GATE-REUSE-TREE-BLIND')
	public function testOneCommitMainMovedByRunsTheWholeBattery(): Void {
		final trees: Array<String> = landed(true);
		Assert.notEquals(trees[0], trees[1]);
		Assert.same([], GateReuse.rows(passing(trees[0]), facts(trees[1])));
		Assert.stringContains('the gate judged', GateReuse.report(passing(trees[0]), facts(trees[1]), []));
	}

	@:pin('control')
	@:killer('M-GATE-REUSE-SKIPPED-COVERS')
	public function testARowTheGateSkippedIsLeftToTheBattery(): Void {
		final passed: Array<String> = GateReuse.passedRows([
			step('suite', Passed),
			step('corpus', Passed),
			step('jvm', Skipped('neither src/ nor the probe changed')),
			step('kits', Passed),
			step('lint', NotRun('no baseline'))
		]);
		Assert.same(['suite', 'corpus', 'kits'], passed);
		final record: GateRecord = passing('t1');
		record.rows = passed;
		Assert.same(['suite', 'corpus', 'kit probes'], GateReuse.rows(record, facts('t1')));
	}

	@:pin('control')
	@:killer('M-GATE-REUSE-FAIL-TRUSTED')
	public function testAFailedGateNeverStandsForARow(): Void {
		final record: GateRecord = passing('t1');
		record.passed = false;
		Assert.same([], GateReuse.rows(record, facts('t1')));
		Assert.stringContains('failed', GateReuse.report(record, facts('t1'), []));
	}

	public function testAnotherCompilerOrAMovedForkStandsForNothing(): Void {
		final compiler: GateRecord = passing('t1');
		compiler.toolchain = 'Haxe 9';
		Assert.same([], GateReuse.rows(compiler, facts('t1')));
		final fork: GateRecord = passing('t1');
		fork.fork = 'moved';
		Assert.same([], GateReuse.rows(fork, facts('t1')));
	}

	public function testARowTheGateWaivedIsNeverTaken(): Void {
		final record: GateRecord = passing('t1');
		record.allow = ['suite'];
		Assert.same(['jvm probe', 'kit probes'], GateReuse.rows(record, facts('t1')), 'nor the corpus, which reads the waived suite');
		record.allow = ['corpus'];
		Assert.same(['suite', 'jvm probe', 'kit probes'], GateReuse.rows(record, facts('t1')));
	}

	public function testAFullBatteryRunsItsOwnSuiteAndTheCorpusOverIt(): Void {
		final full: GateFacts = facts('t1');
		full.quick = false;
		Assert.same(['jvm probe', 'kit probes'], GateReuse.rows(passing('t1'), full));
		final noSweep: GateRecord = passing('t1');
		noSweep.sweep = null;
		Assert.same(['suite', 'jvm probe', 'kit probes'], GateReuse.rows(noSweep, facts('t1')));
	}

	@:pin('control')
	@:killer('M-GATE-REUSE-LOCATE-ANY')
	public function testARecordIsReadOnlyFromTheGateLogsOfTheWorktreeHoldingTheBranch(): Void {
		TempDir.with(dir -> {
			final repo: String = dir.file('repo');
			FileSystem.createDirectory(repo);
			git(repo, ['init', '-q', '-b', 'main']);
			File.saveContent('$repo/a.txt', 'a\n');
			git(repo, ['add', '.']);
			git(repo, ['commit', '-q', '-m', 'base']);
			git(repo, ['branch', BRANCH]);
			final tree: String = dir.file('wt');
			git(repo, ['worktree', 'add', '-q', tree, BRANCH]);
			Assert.isNull(GateReuse.locate(repo, BRANCH), 'no gate ran');
			FileSystem.createDirectory('$tree/slice-gate');
			File.saveContent('$tree/slice-gate/${GateReuse.FILE}', '{}');
			Assert.isNull(GateReuse.locate(repo, BRANCH), 'a record the branch carries is never read');
			FileSystem.createDirectory('$tree-logs/slice-gate');
			File.saveContent('$tree-logs/slice-gate/${GateReuse.FILE}', '{}');
			final found: Null<String> = GateReuse.locate(repo, BRANCH);
			Assert.isTrue(found != null && found.endsWith('wt-logs/slice-gate/${GateReuse.FILE}'), 'found $found');
			Assert.isNull(GateReuse.locate(repo, 'batch/hxqb-S2'), 'another branch has no gate');
			Assert.isNull(GateReuse.read('$tree-logs/slice-gate/${GateReuse.FILE}'), 'a file that is no record is none');
		});
	}

	public function testARecordReadsBackAsWritten(): Void {
		TempDir.with(dir -> {
			final file: String = dir.file(GateReuse.FILE);
			GateReuse.write(file, passing('t1'));
			final back: Null<GateRecord> = GateReuse.read(file);
			Assert.notNull(back);
			if (back != null) Assert.same(passing('t1'), back);
		});
	}

	@:pin('control')
	@:killer('M-GATE-REUSE-MOVED-TREE-PASSES')
	public function testACheckWhoseTreeMovedWhileItRanRecordsNoPass(): Void {
		Assert.isTrue(GateReuse.heldTree(true, 't1', 't1'));
		Assert.isFalse(GateReuse.heldTree(true, 't1', 't2'), 'a commit or amend in the worktree while the rows ran');
		Assert.isFalse(GateReuse.heldTree(false, 't1', 't1'));
	}

	/** The tree a gate judged on the slice's tip, then the tree a land of it onto `main` commits, `main` moved one commit or not. */
	private static function landed(moved: Bool): Array<String> {
		return TempDir.with(dir -> {
			final repo: String = dir.file('repo');
			FileSystem.createDirectory(repo);
			git(repo, ['init', '-q', '-b', 'main']);
			File.saveContent('$repo/a.txt', 'a\n');
			git(repo, ['add', '.']);
			git(repo, ['commit', '-q', '-m', 'base']);
			git(repo, ['checkout', '-q', '-b', BRANCH]);
			File.saveContent('$repo/b.txt', 'b\n');
			git(repo, ['add', '.']);
			git(repo, ['commit', '-q', '-m', 'slice']);
			final gated: String = GateReuse.treeOf(repo);
			git(repo, ['checkout', '-q', 'main']);
			if (moved) {
				File.saveContent('$repo/c.txt', 'c\n');
				git(repo, ['add', '.']);
				git(repo, ['commit', '-q', '-m', 'main moved']);
			}
			git(repo, ['cherry-pick', BRANCH]);
			return [gated, GateReuse.treeOf(repo)];
		});
	}

	private static function passing(tree: String): GateRecord {
		return {
			tree: tree,
			passed: true,
			toolchain: 'Haxe 4',
			fork: '',
			allow: [],
			rows: ['suite', 'lists', 'corpus', 'fmt', 'lint', 'jvm', 'kits'],
			tests: 5,
			assertions: 6,
			sweep: '/logs/${GateReuse.SWEEP}'
		};
	}

	private static function facts(tree: String): GateFacts {
		return {
			tree: tree,
			toolchain: 'Haxe 4',
			fork: '',
			quick: true
		};
	}

	private static function step(name: String, outcome: Outcome): Step {
		return {
			name: name,
			outcome: outcome,
			ms: 0,
			note: '',
			excerpt: []
		};
	}

	private static function git(repo: String, words: Array<String>): Void {
		cmd('git -c user.name=gate -c user.email=gate@example.com -c commit.gpgsign=false -C $repo $words').run().check();
	}

}

package unit.dev;

import anyparse.query.ShardPlan;
import dev.GateRecord;
import dev.GateReuse;
import dev.GateTree;
import dev.SuiteImpact.SuiteScope;
import dev.SuiteReuse;
import devkit.Cmd.cmd;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * `SuiteReuse`: a later check of a worktree keeps the pass of a selected class only when the record of the last vouching
 * check holds it and the change since that record's tree reaches it not, under the same compiler, node and fork; the corpus
 * class keeps its pass only with its snapshot, which goes back into the tree.
 */
@:nullSafety(Strict)
final class SuiteReuseTest extends Test {

	private static final TREE: String = '1111111111111111111111111111111111111111';

	@:pin('control')
	@:killer('M-SUITE-REUSE-REACH-BLIND')
	public function testAClassTheChangeSinceTheRecordReachesNotKeepsItsPass(): Void {
		final split: SuiteSplit = SuiteReuse.split(record(['a.A', 'a.B', 'a.C']), facts(), ['a.A', 'a.B', 'a.C'], ['a.B']);
		Assert.same(['a.B'], split.run);
		Assert.same(['a.A', 'a.C'], split.kept);
		Assert.equals(TREE, split.from);
		Assert.equals('; 2 kept from ${GateTree.short(TREE)}', SuiteReuse.note(split));
		Assert.isFalse(SuiteReuse.keptEvery(split));
		Assert.isTrue(SuiteReuse.keptEvery(SuiteReuse.split(record(['a.A']), facts(), ['a.A'], [])), 'a re-gate of the same tree');
	}

	@:pin('control')
	@:killer('M-SUITE-REUSE-VOUCHED-BLIND')
	public function testOnlyAClassTheRecordVouchedForIsKept(): Void {
		final split: SuiteSplit = SuiteReuse.split(record(['a.A']), facts(), ['a.A', 'a.D'], []);
		Assert.same(['a.D'], split.run, 'selected since the record, so its suite never ran it');
		Assert.same(['a.A'], split.kept);
		final whole: GateRecord = record(null);
		Assert.same(['a.A', 'a.D'], SuiteReuse.split(whole, facts(), ['a.A', 'a.D'], []).kept, 'a whole suite vouched for every class');
	}

	@:pin('control')
	@:killer('M-SUITE-REUSE-CORPUS-SNAPSHOT-BLIND')
	public function testTheCorpusClassKeepsItsPassOnlyWithItsSnapshot(): Void {
		final corpus: String = ShardPlan.CORPUS_CLASS;
		final bare: GateRecord = record([corpus]);
		Assert.same([corpus], SuiteReuse.split(bare, facts(), [corpus], []).run);
		final swept: GateRecord = record([corpus]);
		swept.sweep = '/logs/${SuiteReuse.SWEEP}';
		Assert.same([corpus], SuiteReuse.split(swept, facts(), [corpus], []).kept);
	}

	@:pin('control')
	@:killer('M-SUITE-REUSE-WHOLE-REACHES-NOTHING')
	public function testAChangeThatReachesEveryClassKeepsNone(): Void {
		Assert.isNull(SuiteReuse.reachedIn(WholeSuite('src/anyparse/macro/Build.hx is a macro')));
		Assert.isNull(SuiteReuse.reachedIn(Trimmed('a macro depends on the change', ['a.A'], 1)));
		Assert.same(['a.A'], SuiteReuse.reachedIn(Selected(['a.A'])));
		final split: SuiteSplit = SuiteReuse.split(record(['a.A']), facts(), ['a.A'], null);
		Assert.same(['a.A'], split.run);
		Assert.isNull(split.from);
	}

	@:pin('control')
	@:killer('M-SUITE-REUSE-TOOLCHAIN-BLIND')
	public function testAnotherCompilerNodeOrForkKeepsNothing(): Void {
		final compiler: GateFacts = facts();
		compiler.toolchain = 'Haxe 5';
		Assert.same(['a.A'], SuiteReuse.split(record(['a.A']), compiler, ['a.A'], []).run);
		final node: GateFacts = facts();
		node.node = 'v22.0.0';
		Assert.notNull(SuiteReuse.refusal(record(['a.A']), node));
		final fork: GateFacts = facts();
		fork.fork = 'moved';
		Assert.notNull(SuiteReuse.refusal(record(['a.A']), fork));
		Assert.isNull(SuiteReuse.refusal(record(['a.A']), facts()));
	}

	@:pin('control')
	@:killer('M-SUITE-REUSE-VOUCHES-ALWAYS')
	public function testOnlyAnUnwaivedSuitePassOnAHeldCleanTreeVouches(): Void {
		Assert.isTrue(SuiteReuse.vouches(record(['a.A']), true));
		Assert.isFalse(SuiteReuse.vouches(record(['a.A']), false), 'a commit or amend while the rows ran');
		final failed: GateRecord = record(['a.A']);
		failed.rows = ['porcelain'];
		Assert.isFalse(SuiteReuse.vouches(failed, true));
		final dirty: GateRecord = record(['a.A']);
		dirty.rows = ['suite'];
		Assert.isFalse(SuiteReuse.vouches(dirty, true), 'the porcelain row found the tree unclean');
		final waived: GateRecord = record(['a.A']);
		waived.allow = ['suite'];
		Assert.isFalse(SuiteReuse.vouches(waived, true), '--allow suite turns a red suite into a pass');
	}

	@:pin('control')
	@:killer('M-SUITE-REUSE-GONE-TREE-UNCHANGED')
	public function testATreeGitNoLongerHasIsNoChangeSet(): Void {
		TempDir.with(dir -> {
			final repo: String = committed(dir.file('repo'));
			final recorded: String = GateReuse.treeOf(repo);
			File.saveContent('$repo/a.txt', 'moved\n');
			Assert.same(['a.txt'], SuiteReuse.changedSince(repo, recorded));
			Assert.isNull(SuiteReuse.changedSince(repo, TREE));
		});
	}

	@:pin('control')
	@:killer('M-SUITE-REUSE-SNAPSHOT-NOT-BACK')
	public function testAKeptCorpusClassPutsItsSnapshotBack(): Void {
		TempDir.with(dir -> {
			final repo: String = committed(dir.file('repo'));
			final logs: String = dir.file('logs');
			FileSystem.createDirectory(logs);
			final split: SuiteSplit = vouchedThenMoved(repo, logs);
			Assert.same(['a.B'], split.run);
			Assert.same(['a.A', ShardPlan.CORPUS_CLASS], split.kept);
			Assert.equals('snapshot\n', File.getContent(Path.join([repo, GateTree.SWEEP_SNAPSHOT])));
		});
	}

	@:pin('control')
	@:killer('M-SUITE-REUSE-NOTHING-RECORDED')
	public function testAVouchingCheckLeavesTheRecordTheNextCheckKeepsFrom(): Void {
		TempDir.with(dir -> {
			final repo: String = committed(dir.file('repo'));
			final logs: String = dir.file('logs');
			FileSystem.createDirectory(logs);
			Assert.same(['a.B'], vouchedThenMoved(repo, logs).run);
			final kept: Null<GateRecord> = GateReuse.read(Path.join([logs, SuiteReuse.FILE]));
			Assert.same(['a.A', ShardPlan.CORPUS_CLASS], kept?.vouched);
			Assert.equals(Path.join([logs, SuiteReuse.SWEEP]), kept?.sweep);
		});
	}

	@:pin('control')
	@:killer('M-SUITE-REUSE-UNVOUCHED-OVERWRITES')
	public function testACheckThatDoesNotVouchLeavesTheEarlierRecordStanding(): Void {
		TempDir.with(dir -> {
			final repo: String = committed(dir.file('repo'));
			final logs: String = dir.file('logs');
			FileSystem.createDirectory(logs);
			SuiteReuse.ran(logs, ['a.A']);
			final vouching: GateRecord = record(null);
			vouching.tree = GateReuse.treeOf(repo);
			SuiteReuse.keep(repo, logs, vouching, true);
			final failed: GateRecord = record(null);
			failed.rows = ['porcelain'];
			failed.tree = TREE;
			SuiteReuse.keep(repo, logs, failed, true);
			Assert.equals(GateReuse.treeOf(repo), GateReuse.read(Path.join([logs, SuiteReuse.FILE]))?.tree);
		});
	}

	/**
	 * A vouching check of `repo` that ran `a.A` and the corpus class, then a change the next check's scope reaches `a.B`
	 * through, planned for `a.A`, the corpus class and `a.B`.
	 */
	private static function vouchedThenMoved(repo: String, logs: String): SuiteSplit {
		final snapshot: String = Path.join([repo, GateTree.SWEEP_SNAPSHOT]);
		FileSystem.createDirectory(Path.directory(snapshot));
		File.saveContent(snapshot, 'snapshot\n');
		final vouching: GateRecord = record(null);
		vouching.impact = 2;
		vouching.tree = GateReuse.treeOf(repo);
		SuiteReuse.ran(logs, ['a.A', ShardPlan.CORPUS_CLASS]);
		SuiteReuse.keep(repo, logs, vouching, true);
		GateTree.clearSnapshotIn(repo);
		File.saveContent('$repo/a.txt', 'moved\n');
		final scopeOf: Array<String> -> SuiteScope = touched -> Selected(touched.contains('a.txt') ? ['a.B'] : []);
		return SuiteReuse.plan(repo, logs, facts(), ['a.A', ShardPlan.CORPUS_CLASS, 'a.B'], scopeOf);
	}

	/** A repository at `repo` with one commit, its `bin` ignored as a worktree's is. */
	private static function committed(repo: String): String {
		FileSystem.createDirectory(repo);
		git(repo, ['init', '-q', '-b', 'main']);
		File.saveContent('$repo/.gitignore', 'bin/\n');
		File.saveContent('$repo/a.txt', 'a\n');
		git(repo, ['add', '.']);
		git(repo, ['commit', '-q', '-m', 'base']);
		return repo;
	}

	/** The record of a check whose suite passed on a clean tree, vouching for `vouched` (null: a whole suite). */
	private static function record(vouched: Null<Array<String>>): GateRecord {
		return {
			tree: TREE,
			passed: true,
			toolchain: 'Haxe 4',
			node: 'v20.1.0',
			fork: '',
			allow: [],
			rows: ['suite', 'lists', 'porcelain'],
			tests: 5,
			assertions: 6,
			impact: vouched?.length,
			sweep: null,
			timings: null,
			vouched: vouched
		};
	}

	private static function facts(): GateFacts {
		return {
			tree: TREE,
			toolchain: 'Haxe 4',
			node: 'v20.1.0',
			fork: '',
			quick: true
		};
	}

	private static function git(repo: String, words: Array<String>): Void {
		cmd('git -c user.name=gate -c user.email=gate@example.com -c commit.gpgsign=false -C $repo $words').run().check();
	}

}

package unit.dev;

import dev.GateTree;
import devkit.Result;
import devkit.TempDir;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

/** `dev.GateTree`: the paths a slice changed, a renamed one paired with the path it had at the base. */
@:nullSafety(Strict)
final class GateTreeTest extends Test {

	@:pin('control')
	@:killer('M-GATE-RENAME-UNPAIRED')
	public function testARenameIsPairedWithItsBasePath(): Void {
		final changed: ChangedPaths = GateTree.changedPaths('M\ta/B.hx\nR087\told/C.hx\tnew/C.hx\nA\td/E.hx\n');
		Assert.same(['a/B.hx', 'new/C.hx', 'd/E.hx'], changed.paths);
		Assert.equals('old/C.hx', changed.moved['new/C.hx']);
		Assert.isFalse(changed.moved.exists('a/B.hx'));
	}

	@:pin('control')
	@:killer('M-GATE-TREE-STATE-BLIND')
	public function testATreeStateMovesWithWhatTheTreeHolds(): Void {
		TempDir.with(dir -> {
			FileSystem.createDirectory(dir.file('pkg'));
			File.saveContent(dir.file('pkg/A.hx'), 'class A {}');
			final before: String = GateTree.treeState(dir.path);
			Assert.equals(before, GateTree.treeState(dir.path));
			File.saveContent(dir.file('pkg/A.hx'), 'class A { var x: Int; }');
			Assert.notEquals(before, GateTree.treeState(dir.path));
		});
	}

	public function testALoggedCommandKeepsStandardErrorOffThePipe(): Void {
		TempDir.with(dir -> {
			final errLog: String = dir.file('err.log');
			final run: Result = GateTree.logged(['sh', '-c', 'echo out; echo "err $1" >&2', 'sh', 'a b'], errLog).run();
			Assert.equals('out\n', run.out);
			Assert.equals('', run.err);
			Assert.equals('err a b\n', File.getContent(errLog));
			Assert.isTrue(GateTree.logged(['sh', '-c', 'echo second >&2'], errLog).run().ok);
			Assert.equals('second\n', File.getContent(errLog));
		});
	}

	@:pin('control')
	@:killer('M-GATE-CORPUS-SHORTFALL-SKIPPED')
	@:killer('M-GATE-CORPUS-FORK-SKIPPED')
	public function testOnlyAnImpactRunWithoutTheCorpusClassLeavesTheCorpusRowSkipped(): Void {
		final missing: String = 'no snapshot';
		final failed: String = 'Failed($missing)';
		Assert.isNull(GateTree.corpusShortfall(null, null, ['unit.query.OtherTest']));
		Assert.stringContains(
			'Skipped(', Std.string(GateTree.corpusShortfall(null, missing, ['unit.query.OtherTest'])), 'no corpus class ran'
		);
		Assert.equals(failed, Std.string(GateTree.corpusShortfall(null, missing, [GateTree.CORPUS_CLASS])), 'the corpus class ran');
		Assert.equals(failed, Std.string(GateTree.corpusShortfall(null, missing, null)), 'every class ran');
		Assert.equals('Failed(no fork)', Std.string(GateTree.corpusShortfall('no fork', missing, [])), 'a bad fork is no impact choice');
	}

	/**
	 * A slice that touches neither the engine's sources, its build files nor
	 * `apq.json` is engine-free: the rows that only measure the engine skip.
	 */
	@:pin('guard')
	public function testOnlyTheEnginesOwnFilesAreEngineInputs(): Void {
		for (file in [
			'src/anyparse/core/A.hx',
			'bin/apq-js.hxml',
			'bin/apq-launch-common.hxml',
			'bin/apq',
			'bin/hxq',
			'apq.json'
		]) Assert.isTrue(GateTree.isEngineInput(file), file);
		for (file in [
			'test/unit/dev/A.hx',
			'tools/src/dev/A.hx',
			'docs/testing.md',
			'apqlint.json',
			'bin/test.js',
			'bin/apq.js',
			'bin/hxq2',
			'test/src/apq.json',
			'tools/bin/apq-js.hxml'
		]) Assert.isFalse(GateTree.isEngineInput(file), file);
	}

	/**
	 * The fmt row's project half formats the whole tree only when the engine
	 * or a formatter config moved, else the touched `.hx` files alone.
	 */
	@:pin('guard')
	public function testTheFmtRowFormatsTheWholeTreeOnlyWhenTheEngineOrAConfigMoved(): Void {
		Assert.same(GateTree.TREE_SCOPE, GateTree.fmtScope(['src/anyparse/core/A.hx']));
		Assert.same(GateTree.TREE_SCOPE, GateTree.fmtScope(['apq.json']));
		Assert.same(GateTree.TREE_SCOPE, GateTree.fmtScope(['hxformat.json']));
		Assert.same(GateTree.TREE_SCOPE, GateTree.fmtScope(['.hxformat.json', 'docs/a.md']));
		Assert.same(['test/unit/A.hx', 'tools/src/B.hx'], GateTree.fmtScope(['test/unit/A.hx', 'docs/a.md', 'tools/src/B.hx']));
		Assert.same([], GateTree.fmtScope(['docs/a.md', 'bin/test.js', '.claude/batch/q.md']));
	}

	/** The jvm probe runs for an engine input and for the probe's own source and build file, and for nothing else. */
	@:pin('guard')
	public function testTheJvmProbeRunsForTheEngineAndItsOwnFiles(): Void {
		for (file in [
			'src/anyparse/core/A.hx',
			'bin/hxq',
			'apq.json',
			'tools/src/dev/JvmPortability.hx',
			'tools/jvm-portability.hxml'
		]) Assert.isTrue(GateTree.isJvmInput(file), file);
		for (file in [
			'tools/src/dev/GateTree.hx',
			'tools/bench-hxcpp.hxml',
			'test/unit/A.hx',
			'docs/testing.md'
		]) Assert.isFalse(GateTree.isJvmInput(file), file);
	}

}

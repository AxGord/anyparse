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

}

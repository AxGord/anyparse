package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Glob;
#if sys
import sys.io.File;
import sys.FileSystem;
#end

/**
 * Unit coverage for `Glob.expand` — the apq input resolver. Builds a
 * throwaway directory tree under cwd, then drives every supported
 * positional form (single file, directory, `*`, `**`, `?`, `[...]`)
 * and asserts the resolved file set. Non-sys targets pass trivially.
 *
 * `teardown` always runs (even on a failing assertion), so a broken
 * test never leaks a `tmp_glob_*` directory into the repo root.
 */
class GlobExpandTest extends Test {

	#if sys
	private static var counter: Int = 0;

	private var _root: Null<String> = null;
	#end

	public function testSingleStarWithinSegment(): Void {
		#if sys
		final root: String = makeTree();
		final got: Array<String> = Glob.expand('$root/sub/*.hx', '.hx');
		Assert.equals(3, got.length);
		Assert.isTrue(got.contains('$root/sub/HxFoo.hx'));
		Assert.isTrue(got.contains('$root/sub/HxBar.hx'));
		Assert.isTrue(got.contains('$root/sub/other.hx'));
		Assert.isFalse(got.contains('$root/sub/deep/HxDeep.hx'));
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testDoubleStarAcrossSegments(): Void {
		#if sys
		final root: String = makeTree();
		final got: Array<String> = Glob.expand('$root/**/Hx*.hx', '.hx');
		Assert.equals(3, got.length);
		Assert.isTrue(got.contains('$root/sub/HxFoo.hx'));
		Assert.isTrue(got.contains('$root/sub/HxBar.hx'));
		Assert.isTrue(got.contains('$root/sub/deep/HxDeep.hx'));
		Assert.isFalse(got.contains('$root/a.hx'));
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testQuestionMarkSingleChar(): Void {
		#if sys
		final root: String = makeTree();
		final got: Array<String> = Glob.expand('$root/?.hx', '.hx');
		Assert.equals(1, got.length);
		Assert.isTrue(got.contains('$root/a.hx'));
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testCharClass(): Void {
		#if sys
		final root: String = makeTree();
		final got: Array<String> = Glob.expand('$root/sub/Hx[FB]*.hx', '.hx');
		Assert.equals(2, got.length);
		Assert.isTrue(got.contains('$root/sub/HxFoo.hx'));
		Assert.isTrue(got.contains('$root/sub/HxBar.hx'));
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testDirectoryRecursesUnchanged(): Void {
		#if sys
		final root: String = makeTree();
		final got: Array<String> = Glob.expand(root, '.hx');
		Assert.equals(5, got.length);
		Assert.isFalse(got.contains('$root/b.txt'));
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testSingleFileUnchanged(): Void {
		#if sys
		final root: String = makeTree();
		final got: Array<String> = Glob.expand('$root/a.hx', '.hx');
		Assert.equals(1, got.length);
		Assert.equals('$root/a.hx', got[0]);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testNoMatchReturnsEmpty(): Void {
		#if sys
		final root: String = makeTree();
		Assert.equals(0, Glob.expand('$root/sub/*.cpp', '.hx').length);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if sys
	public function teardown(): Void {
		final root: Null<String> = _root;
		if (root != null && FileSystem.exists(root)) CliFixture.removeDir(root);
		_root = null;
	}

	private function makeTree(): String {
		counter++;
		final root: String = '${haxe.io.Path.normalize(Sys.getCwd())}/tmp_glob_${Sys.time()}_$counter';
		_root = root;
		FileSystem.createDirectory('$root/sub/deep');
		File.saveContent('$root/a.hx', '');
		File.saveContent('$root/b.txt', '');
		File.saveContent('$root/sub/HxFoo.hx', '');
		File.saveContent('$root/sub/HxBar.hx', '');
		File.saveContent('$root/sub/other.hx', '');
		File.saveContent('$root/sub/deep/HxDeep.hx', '');
		return root;
	}
	#end

}

package unit;

import anyparse.query.HaxelibResolver;
import utest.Assert;
import utest.Test;

/**
 * Coverage of the PURE `HaxelibResolver` assembly (`sourceDirFrom` / `rootFrom`)
 * with NO real haxelib: given a `haxelib libpath` stdout string plus a
 * `haxelib.json` content, it computes the source dir. The single impure edge (the
 * `haxelib libpath` spawn) is exercised only by the manual openfl e2e; every
 * decision it feeds is unit-tested here, so the path-assembly logic has real
 * coverage without an installed lib.
 */
class HaxelibResolverTest extends Test {

	/** The openfl shape: a trailing-newline root plus `classPath: "src"` joins to `<root>/src`. */
	public function testClassPathSrcJoinsRoot(): Void {
		Assert.equals('/Users/x/openfl/src', HaxelibResolver.sourceDirFrom('/Users/x/openfl/\n', '{"classPath":"src","version":"9.0.0"}'));
	}

	/** Leading/trailing whitespace on the libpath output is trimmed before joining. */
	public function testLibpathWhitespaceTrimmed(): Void {
		Assert.equals('/a/b/src', HaxelibResolver.sourceDirFrom('  /a/b  \n', '{"classPath":"src"}'));
	}

	/** An empty `classPath` means the source is the root itself. */
	public function testEmptyClassPathIsRoot(): Void {
		Assert.equals('/a/b', HaxelibResolver.sourceDirFrom('/a/b\n', '{"classPath":""}'));
	}

	/** An absent `classPath` key defaults to the root (a root-sourced lib). */
	public function testAbsentClassPathIsRoot(): Void {
		Assert.equals('/a/b', HaxelibResolver.sourceDirFrom('/a/b', '{"name":"foo","version":"1.0.0"}'));
	}

	/** A non-string `classPath` is ignored — falls back to the root. */
	public function testNonStringClassPathIsRoot(): Void {
		Assert.equals('/a/b', HaxelibResolver.sourceDirFrom('/a/b', '{"classPath":42}'));
	}

	/** The joined path is normalised — a `./` segment in `classPath` collapses. */
	public function testJoinedPathNormalised(): Void {
		Assert.equals('/a/b/src', HaxelibResolver.sourceDirFrom('/a/b/', '{"classPath":"./src"}'));
	}

	/** Malformed `haxelib.json` yields null — the lib is skipped, not indexed from an unknown root. */
	public function testMalformedJsonIsNull(): Void {
		Assert.isNull(HaxelibResolver.sourceDirFrom('/a/b', 'not json at all'));
	}

	/** A non-object JSON root (a bare scalar) yields null. */
	public function testScalarJsonIsNull(): Void {
		Assert.isNull(HaxelibResolver.sourceDirFrom('/a/b', '42'));
	}

	/** A null `haxelib.json` (file missing/unreadable) yields null. */
	public function testNullJsonIsNull(): Void {
		Assert.isNull(HaxelibResolver.sourceDirFrom('/a/b', null));
	}

	/** Empty libpath output (lib not installed / nothing printed) yields null even with a valid json. */
	public function testEmptyLibpathIsNull(): Void {
		Assert.isNull(HaxelibResolver.sourceDirFrom('   \n', '{"classPath":"src"}'));
	}

	/** `rootFrom` trims the output and null-guards the empty case. */
	public function testRootFrom(): Void {
		Assert.equals('/a/b', HaxelibResolver.rootFrom('  /a/b \n'));
		Assert.isNull(HaxelibResolver.rootFrom('   '));
		Assert.isNull(HaxelibResolver.rootFrom(''));
	}


	/**
	 * The full impure path against a REAL installed lib — `utest`, guaranteed present since it IS the
	 * test framework: `libSourceDir` spawns `haxelib libpath`, reads the lib's `haxelib.json`
	 * (`classPath: "src"`) and returns the normalised `<root>/src`. Skips gracefully when `haxelib`
	 * is off PATH so the suite never hard-depends on the launcher being reachable.
	 */
	public function testLibSourceDirResolvesRealInstalledLib(): Void {
		final dir: Null<String> = HaxelibResolver.libSourceDir('utest');
		if (dir == null) {
			Assert.pass('haxelib not on PATH — real-lib resolution skipped');
			return;
		}
		Assert.isTrue(haxe.io.Path.isAbsolute(dir), 'the resolved source dir is absolute');
		Assert.isTrue(StringTools.endsWith(dir, '/src'), 'utest classPath "src" joins to <root>/src, got $dir');
		#if (sys || nodejs)
		Assert.isTrue(sys.FileSystem.isDirectory(dir), 'the resolved utest source dir exists on disk');
		#end
	}

}

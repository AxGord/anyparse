package unit;

import anyparse.query.StdResolver;
import anyparse.query.Glob;
import utest.Assert;
import utest.Test;
#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * Coverage of `StdResolver`: the PURE `discover` priority logic (env override →
 * `which haxe` sibling → known locations) exercised with an injected `exists`
 * predicate and a fixture dir, plus the pure `resolutionSpecs` shape and a live
 * smoke of `stdDir` / the toplevel-only glob against the real installed std
 * (skipped gracefully when no std is on the machine).
 */
class StdResolverTest extends Test {

	/** `HAXE_STD_PATH` wins over every later candidate when it exists. */
	public function testEnvWins(): Void {
		Assert.equals('/fix/std', StdResolver.discover('/fix/std', '/w/std', ['/k/std'], _ -> true));
	}

	/** A set-but-nonexistent `HAXE_STD_PATH` is skipped, not fatal — the next candidate answers. */
	public function testEnvNonexistentFallsThrough(): Void {
		Assert.equals('/w/std', StdResolver.discover('/bad/std', '/w/std', ['/k/std'], p -> p == '/w/std'));
	}

	/** The `which haxe` sibling wins over the known locations. */
	public function testWhichWinsOverKnown(): Void {
		Assert.equals('/w/std', StdResolver.discover(null, '/w/std', ['/k/std'], _ -> true));
	}

	/** With no env and no `which` sibling, the FIRST existing known location answers. */
	public function testKnownFallbackFirstExisting(): Void {
		Assert.equals('/k2/std', StdResolver.discover(null, null, ['/k1/std', '/k2/std'], p -> p == '/k2/std'));
	}

	/** Among several existing known locations the first wins. */
	public function testKnownFirstWins(): Void {
		Assert.equals('/k1/std', StdResolver.discover(null, null, ['/k1/std', '/k2/std'], _ -> true));
	}

	/** Nothing exists anywhere → null (every consumer then degrades to pre-existing behaviour). */
	public function testNoneFoundIsNull(): Void {
		Assert.isNull(StdResolver.discover(null, null, ['/k/std'], _ -> false));
	}

	/** A trailing slash on a candidate is normalised away. */
	public function testNormalisesTrailingSlash(): Void {
		Assert.equals('/fix/std', StdResolver.discover('/fix/std/', null, [], p -> p == '/fix/std'));
	}

	/**
	 * The env-override against a REAL fixture directory on disk: `discover` with the
	 * genuine filesystem `exists` predicate returns the fixture path (the
	 * `HAXE_STD_PATH`-shaped input) when it is an existing directory.
	 */
	public function testEnvOverrideFixtureDir(): Void {
		#if (sys || nodejs)
		final fixture: String = CliFixture.writeDir('stdfix', [{ name: 'Std.hx', source: 'class Std {}' }]);
		final resolved: Null<String> = StdResolver.discover(fixture, null, [], p -> FileSystem.exists(p) && FileSystem.isDirectory(p));
		Assert.equals(haxe.io.Path.normalize(fixture), resolved);
		CliFixture.removeDir(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `resolutionSpecs` = toplevel `*.hx` glob + the `haxe/` and `sys/` subtree dirs. */
	public function testResolutionSpecsShape(): Void {
		Assert.same(['/a/std/*.hx', '/a/std/haxe', '/a/std/sys'], StdResolver.resolutionSpecs('/a/std'));
	}

	/**
	 * LIVE smoke: on a machine with an installed std, `stdDir` returns an absolute,
	 * existing directory whose `Std.hx` is present. Skips when no std is found.
	 */
	public function testLiveStdDirFound(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = StdResolver.stdDir();
		if (dir == null) {
			Assert.pass('no installed Haxe std on this machine — live discovery skipped');
			return;
		}
		Assert.isTrue(haxe.io.Path.isAbsolute(dir), 'the discovered std dir is absolute, got $dir');
		Assert.isTrue(FileSystem.isDirectory(dir), 'the discovered std dir exists on disk');
		Assert.isTrue(FileSystem.exists(haxe.io.Path.join([dir, 'Std.hx'])), '$dir contains the toplevel Std.hx');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The toplevel `*.hx` glob spec expands to the toplevel core types ONLY — `Std.hx`
	 * is in, target-specific subtrees (`js/`) are out — so the implicit std scope is
	 * the target-agnostic subset, not the whole tree. Skips when no std is found.
	 */
	public function testToplevelGlobIsSubset(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = StdResolver.stdDir();
		if (dir == null) {
			Assert.pass('no installed Haxe std on this machine — glob-subset check skipped');
			return;
		}
		final toplevel: Array<String> = Glob.expand(StdResolver.resolutionSpecs(dir)[0], '.hx');
		Assert.isTrue(toplevel.length > 0, 'the toplevel glob matched at least one core type');
		final hasStd: Bool = Lambda.exists(toplevel, p -> StringTools.endsWith(p, '/Std.hx'));
		Assert.isTrue(hasStd, 'the toplevel glob includes Std.hx');
		final hasTargetSubtree: Bool = Lambda.exists(toplevel, p -> p.indexOf('/js/') >= 0 || p.indexOf('/cpp/') >= 0);
		Assert.isFalse(hasTargetSubtree, 'the toplevel glob excludes target-specific subtrees');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Caching invariant: a second `stdDir` call never re-runs the impure discovery. */
	public function testCachingInvariant(): Void {
		StdResolver.stdDir();
		final after: Int = StdResolver.discoveries;
		StdResolver.stdDir();
		Assert.equals(after, StdResolver.discoveries, 'the cached second call does not increment the discovery counter');
	}

}

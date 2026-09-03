package unit.query;

#if (sys || nodejs)
import sys.FileSystem;
#end
import anyparse.query.Glob;
import anyparse.query.StdResolver;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;
using Lambda;

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

	/** A file under the root is inside it. */
	public function testIsUnderInside(): Void {
		Assert.isTrue(StdResolver.isUnder('/opt/haxe/std', '/opt/haxe/std/haxe/ds/BalancedTree.hx'));
	}

	/** The root itself is not strictly inside the root. */
	public function testIsUnderRootItself(): Void {
		Assert.isFalse(StdResolver.isUnder('/opt/haxe/std', '/opt/haxe/std'));
	}

	/** A sibling whose name merely STARTS with the root is outside it — the separator is required. */
	public function testIsUnderSiblingPrefixIsOutside(): Void {
		Assert.isFalse(StdResolver.isUnder('/opt/haxe/std', '/opt/haxe/std-old/haxe/X.hx'));
	}

	/** A trailing slash on the root changes nothing. */
	public function testIsUnderTrailingSlashRoot(): Void {
		Assert.isTrue(StdResolver.isUnder('/opt/haxe/std/', '/opt/haxe/std/haxe/X.hx'));
	}

	/** `.` / `..` segments are resolved before the compare, so a detour through the parent still counts. */
	public function testIsUnderNormalisesDotSegments(): Void {
		Assert.isTrue(StdResolver.isUnder('/opt/haxe/std', '/opt/haxe/std/haxe/../haxe/X.hx'));
	}

	/** Backslashes are folded, so a Windows-spelled path compares against a Windows-spelled root. */
	public function testIsUnderFoldsBackslashes(): Void {
		Assert.isTrue(StdResolver.isUnder('C:\\haxe\\std', 'C:\\haxe\\std\\haxe\\X.hx'));
	}

	/** A RELATIVE path can never be inside an absolute root — the answer that keeps report files in a std-excluding scan. */
	public function testIsUnderRelativePathIsOutside(): Void {
		Assert.isFalse(StdResolver.isUnder('/opt/haxe/std', 'src/A.hx'));
	}

	/** `isStdFile` answers off the discovered root: a project path is never std. */
	public function testIsStdFileRejectsAProjectPath(): Void {
		Assert.isFalse(StdResolver.isStdFile('/some/project/src/A.hx'));
	}

	/** `isStdFile` accepts a path under the real discovered std (skipped when the machine has none). */
	public function testIsStdFileAcceptsADiscoveredStdPath(): Void {
		final std: Null<String> = StdResolver.stdDir();
		if (std == null) {
			Assert.pass();
			return;
		}
		Assert.isTrue(StdResolver.isStdFile(haxe.io.Path.join([std, 'haxe', 'ds', 'BalancedTree.hx'])));
	}

	/**
	 * A `HAXE_STD_PATH` aimed at a tree that is NOT a std (no toplevel `Std.hx`) attributes
	 * nothing to std. `stdDir` still answers with it — its other consumers only over-scan — but
	 * a consumer that EXCLUDES std files must not be tricked into skipping a project tree.
	 */
	public function testIsStdFileRejectsANonStdRoot(): Void {
		#if (sys || nodejs)
		final fixture: String = CliFixture.writeDir('notstd', [{ name: 'CrashDumper.hx', source: 'class CrashDumper {}' }]);
		final answer: Bool = stdFileUnder(fixture, 'CrashDumper.hx');
		CliFixture.removeDir(fixture);
		Assert.isFalse(answer, 'a root without the std marker attributes nothing');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The same fixture WITH the toplevel `Std.hx` marker is accepted — the gate tests the marker, not the fixture. */
	public function testIsStdFileAcceptsAMarkedRoot(): Void {
		#if (sys || nodejs)
		final fixture: String = CliFixture.writeDir('markedstd', [{ name: 'Std.hx', source: 'class Std {}' }]);
		final answer: Bool = stdFileUnder(fixture, 'haxe/ds/BalancedTree.hx');
		CliFixture.removeDir(fixture);
		Assert.isTrue(answer, 'a root carrying the std marker attributes its files');
		#else
		Assert.pass('non-sys target');
		#end
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
		final hasStd: Bool = toplevel.exists(p -> StringTools.endsWith(p, '/Std.hx'));
		Assert.isTrue(hasStd, 'the toplevel glob includes Std.hx');
		final hasTargetSubtree: Bool = toplevel.exists(p -> p.indexOf('/js/') >= 0 || p.indexOf('/cpp/') >= 0);
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

	/**
	 * `APQ_NO_STD` DECLINES the std outright — the only opt-out that works on a machine where
	 * `KNOWN_LOCATIONS` finds `/usr/local/lib/haxe/std` or `/opt/homebrew/lib/haxe/std` no
	 * matter what `HAXE_STD_PATH` and `PATH` say. Without it every "no std" branch —
	 * `Cli.resolutionThunk`'s `return null`, `wrapResolution`'s passthrough, the std-derived
	 * tables' fallbacks — is unreachable on any Haxe-equipped box, i.e. dead in CI.
	 *
	 * Uses the `resetCache` seam on BOTH sides, since `stdDir` memoises per process.
	 */
	public function testEnvOptOutDeclinesTheStd(): Void {
		#if (sys || nodejs)
		final live: Null<String> = StdResolver.stdDir();
		if (live == null) {
			Assert.pass('no installed Haxe std on this machine — the opt-out has nothing to decline');
			return;
		}
		StdResolver.resetCache();
		Sys.putEnv('APQ_NO_STD', '1');
		final declined: Null<String> = StdResolver.stdDir();
		Sys.putEnv('APQ_NO_STD', '');
		StdResolver.resetCache();
		Assert.isNull(declined, 'APQ_NO_STD=1 declines the std even though the known locations hold one');
		Assert.equals(live, StdResolver.stdDir(), 'clearing it restores the real std for the rest of the suite');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Only a non-empty, non-`0` value declines — so a stray empty export cannot silently disable the whole std channel. */
	public function testEnvOptOutIgnoresEmptyAndZero(): Void {
		#if (sys || nodejs)
		final live: Null<String> = StdResolver.stdDir();
		if (live == null) {
			Assert.pass('no installed Haxe std on this machine — the opt-out has nothing to decline');
			return;
		}
		StdResolver.resetCache();
		Sys.putEnv('APQ_NO_STD', '0');
		final withZero: Null<String> = StdResolver.stdDir();
		Sys.putEnv('APQ_NO_STD', '');
		StdResolver.resetCache();
		Assert.equals(live, StdResolver.stdDir(), 'the memo is re-primed, so no later test sees an unexpected discovery');
		Assert.equals(live, withZero, 'APQ_NO_STD=0 keeps the std');
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/**
	 * `isStdFile` for `relative` under `root`, with `HAXE_STD_PATH` pointed at `root` for the
	 * duration. Brackets the env write and the `stdDir` memo on BOTH sides — the memo is
	 * process-wide, so the rest of the suite must come back to the real std.
	 *
	 * The restore passes the ORIGINAL value back, null included: `putEnv` with null REMOVES the
	 * variable, and an unset `HAXE_STD_PATH` is not the same as an empty one — the `haxe`
	 * subprocess the compiler-oracle tests spawn reads it and fails outright on an empty value.
	 */
	private function stdFileUnder(root: String, relative: String): Bool {
		final original: Null<String> = Sys.getEnv('HAXE_STD_PATH');
		StdResolver.resetCache();
		Sys.putEnv('HAXE_STD_PATH', root);
		final answer: Bool = StdResolver.isStdFile(haxe.io.Path.join([root, relative]));
		Sys.putEnv('HAXE_STD_PATH', original);
		StdResolver.resetCache();
		return answer;
	}
	#end

}

package unit.cli;

import haxe.Exception;
import haxe.io.Path;
import utest.Assert;
import utest.Test;
#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * The suite process writes its fixtures inside a PRIVATE scratch root, never the ambient one.
 *
 * `RunTests.main` calls `CliFixture.isolateTempDir()` before it registers a single fixture, and
 * that call is the whole of what keeps two concurrent suite processes — a `mutation-arm.sh`
 * sweep, a `suite-shard.sh` shard set, a second worker on the same machine — from generating the
 * same fixture directory name and deleting each other's files mid-test (S150). Nothing checked
 * it: delete the call and this suite stays green, because the damage lands in ANOTHER process's
 * transcript and only under concurrency.
 *
 * The two assertions are one question in two halves, and neither half alone discriminates: a
 * fixture must be written into the directory `TMPDIR` currently names, and that directory must be
 * a claimed `apq-suite.` root rather than the machine's shared temp. So the isolation cannot be
 * removed, nor moved past `runner.run()`, in silence. Verified by cutting it: with the runner's
 * `isolateTempDir()` swapped for `repoRoot()` both assertions fail and name the shared temp dir.
 *
 * What it deliberately does NOT pin is the call's exact position inside `main`. The strict
 * property is "before any test class is CONSTRUCTED", and that has no observer today, because no
 * test class writes a fixture from its constructor.
 */
@:nullSafety(Strict)
final class ScratchIsolationGateTest extends Test {

	public function testAFixtureLandsInsideTheRunsPrivateScratchRoot(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('scratch_root_gate', 'class C {}\n');
		final dir: String = Path.directory(path);
		// Trailing slash removed on both sides: macOS exports TMPDIR with one and
		// `Path.directory` never returns one, so a raw compare would flip on the slash
		// rather than on the isolation.
		final named: String = Path.removeTrailingSlashes(Sys.getEnv('TMPDIR') ?? '');
		Assert.equals(named, dir, 'a fixture is written into the directory TMPDIR names, got $path');
		Assert.isTrue(
			Path.withoutDirectory(dir).indexOf('apq-suite.') == 0,
			'and that directory is a claimed private scratch root, not the shared temp dir, got $dir'
		);
		FileSystem.deleteFile(path);
		#else
		Assert.fail('the scratch-root gate needs a filesystem');
		#end
	}

	/**
	 * `removeScratchRoot` refuses a path it did not claim, rather than deleting it.
	 *
	 * The teardown it guards is a recursive delete registered on `onComplete`, so a wrong
	 * argument is an `rm -rf` of whatever that argument names — measured the hard way while
	 * this seam was being probed: the runner's `isolateTempDir()` was swapped for `repoRoot()`
	 * for one build, and the run removed the worktree it was running in. `removeDir` itself is
	 * tolerant of a missing path, so WITHOUT the guard this call is a silent no-op and the
	 * assertion fails; the raise is the whole evidence that the predicate runs.
	 */
	public function testRemovingAPathThisClassNeverClaimedIsRefused(): Void {
		Assert.raises(CliFixture.removeScratchRoot.bind('/tmp/anyparse-not-a-claimed-scratch-root'), Exception);
	}

}

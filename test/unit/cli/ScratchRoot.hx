package unit.cli;

import anyparse.core.TempScratch;
#if (sys || nodejs)
import haxe.Exception;
import haxe.io.Path;
import sys.io.File;
import sys.FileSystem;
#end

@:nullSafety(Strict)
final class ScratchRoot {

	/**
	 * The scratch-directory prefix this suite claims, and the one `devkit.TmpLifecycle`
	 * must list in `TMPL_PREFIXES` for an orphaned root to be reaped.
	 */
	private static inline final SCRATCH_PREFIX: String = 'apq-suite';

	/** The owner stamp that script reads: `<dir>/.apq-owner`, first line `pid <pid>`. */
	private static inline final OWNER_STAMP: String = '.apq-owner';

	/** Lowest six-digit value, so the fallback token is always exactly `mktemp`'s six characters. */
	private static inline final SCRATCH_TOKEN_LOW: Int = 100000;

	/** How many six-digit values the fallback token draws from. */
	private static inline final SCRATCH_TOKEN_SPAN: Int = 900000;

	/**
	 * Remove a scratch root this class CLAIMED, and refuse anything else BY NAME.
	 *
	 * `removeDir` deletes whatever it is handed, recursively. Handed the wrong path it is an
	 * `rm -rf` with no undo, and the wrong path is one edit away: while probing this very seam
	 * the runner's teardown was pointed at `repoRoot()` for a single build, and that run
	 * deleted the whole worktree it was running in. `devkit.TmpLifecycle` already refuses a
	 * path outside its shape out loud rather than skipping it quietly (`refusal`); this is
	 * the same predicate on this side of the boundary — a basename of `apq-suite.` plus
	 * `mktemp`'s six characters, sitting under a directory of its own.
	 */
	public static function removeScratchRoot(dir: String): Void {
		final trimmed: String = Path.removeTrailingSlashes(dir);
		final base: String = Path.withoutDirectory(trimmed);
		final claimed: Bool = base.length == SCRATCH_PREFIX.length + 7
			&& base.indexOf('$SCRATCH_PREFIX.') == 0
			&& Path.directory(trimmed) != '';
		if (!claimed) throw new Exception('refusing to remove "$dir" — not a claimed $SCRATCH_PREFIX scratch root');
		removeDir(dir);
	}

	/**
	 * Point this process's `TMPDIR` at a private subdirectory of the OS temp dir and answer
	 * it; the caller removes it when the run ends (`removeScratchRoot`).
	 *
	 * A fixture name is unique only WITHIN a process — `counter` is a static and `Sys.time()`
	 * is a millisecond clock, and neither carries anything a second process cannot produce.
	 * Two suite processes started together are lockstep copies of each other, the same classes
	 * in the same order, so their counters advance side by side and land in the same
	 * millisecond: whole runs of names coincide, both write into ONE directory, and the first
	 * teardown deletes the other's fixture mid-test. Four concurrent suites show it as a run
	 * of non-green rows across several classes, every one of them an `ENOENT` on a
	 * `$TMPDIR/tmp_…` path — and none with a private `TMPDIR` per process.
	 *
	 * A per-process ROOT rather than a per-process NAME because the naming is not in one
	 * place: many sites under test/ build such a path by hand — one of them a FIXED name no
	 * per-name fix could ever have reached — and `OracleCache` / `CompilerServer` key their
	 * records by an hxml+cwd hash under the same directory. One root covers every producer,
	 * including the ones not written yet.
	 *
	 * The root is CLAIMED the way `devkit.TmpLifecycle` claims one — `apq-suite.XXXXXX`
	 * plus a `.apq-owner` stamp naming this pid — so the case the caller's teardown cannot
	 * reach, a SIGKILLed run, is swept by the tool that already owns that job for the other
	 * four scratch producers. Without that shape this would be the project's fifth scratch
	 * directory and the only one nothing reaps.
	 *
	 * The process environment is this call's other concern: it also switches git commit and tag signing off for every
	 * `git` child (`silenceGitSigning`), so a fixture commit never waits on the user's gpg agent.
	 */
	public static function isolateTempDir(): String {
		final dir: String = makeScratchRoot(TempScratch.root());
		#if nodejs
		// The stamp `devkit.TmpLifecycle` reads. Its sweep removes a claimed directory
		// whose owner pid is gone and whose entries have been untouched for the grace
		// window, so the one case the caller's teardown cannot reach — a SIGKILLed run — is
		// covered by the tool that already owns that job for the other four scratch producers.
		File.saveContent('$dir/$OWNER_STAMP', 'pid ${js.Node.process.pid}\ntool $SCRATCH_PREFIX\nstarted ${Std.int(Sys.time())}\n');
		#end
		Sys.putEnv('TMPDIR', dir);
		Sys.putEnv('TEMP', dir);
		silenceGitSigning();
		return dir;
	}

	/**
	 * Recursively delete `dir` and everything beneath it, tolerant of a missing path — a `dir` that does not exist is a
	 * silent no-op. Lives with the scratch root it tears down so the runner reaches no more of the harness than that.
	 */
	public static function removeDir(dir: String): Void {
		if (!FileSystem.exists(dir)) return;
		for (entry in FileSystem.readDirectory(dir)) {
			final p: String = '$dir/$entry';
			if (FileSystem.isDirectory(p))
				removeDir(p);
			else
				FileSystem.deleteFile(p);
		}
		FileSystem.deleteDirectory(dir);
	}

	/**
	 * A fresh `apq-suite.XXXXXX` directory under `root`, created ATOMICALLY — `mkdtemp`
	 * fails rather than adopting an existing entry, which a `createDirectory` on a
	 * predictable name would silently do (hxnodejs swallows `EEXIST` whenever the path
	 * stats as a directory, symlinks followed). The name is `mktemp -d`'s exactly because
	 * `devkit.TmpLifecycle` will only ever remove `<prefix>.` plus six characters.
	 */
	private static function makeScratchRoot(root: String): String {
		#if nodejs
		return js.node.Fs.mkdtempSync('$root/$SCRATCH_PREFIX.');
		#else
		// No portable `mkdtemp`; a six-digit draw keeps the shape mktemp gives and the
		// collision odds, and this branch never runs — the suite's only runner is node.
		final dir: String = '$root/$SCRATCH_PREFIX.${SCRATCH_TOKEN_LOW + Std.random(SCRATCH_TOKEN_SPAN)}';
		FileSystem.createDirectory(dir);
		return dir;
		#end
	}

	/**
	 * Turn commit and tag signing off for every `git` child this process spawns, through git's own environment
	 * configuration (`GIT_CONFIG_COUNT` and its key/value pairs), which outranks the user's global, system and repository files.
	 *
	 * A fixture repository commits as a throwaway identity, and a signing setup inherited from the user's
	 * configuration makes each of those commits depend on a running gpg agent: under load it fails
	 * ("Cannot allocate memory") and the test fails with it. Set once for the process, it covers every producer of a
	 * fixture commit, the ones not written yet included; entries already present are kept.
	 */
	private static function silenceGitSigning(): Void {
		var count: Int = Std.parseInt(Sys.getEnv('GIT_CONFIG_COUNT') ?? '') ?? 0;
		for (key in ['commit.gpgsign', 'tag.gpgsign']) {
			Sys.putEnv('GIT_CONFIG_KEY_$count', key);
			Sys.putEnv('GIT_CONFIG_VALUE_$count', 'false');
			count++;
		}
		Sys.putEnv('GIT_CONFIG_COUNT', '$count');
	}

}

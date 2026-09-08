package anyparse.core;

import haxe.io.Path;

/**
 * Where this process may put a scratch file, and what keeps its scratch apart from
 * every other process's.
 *
 * ONE reading of both halves, because the question had grown five answers that had
 * drifted from each other — `OracleCache.tempDir`, `CompilerServer.stateFile`,
 * `ProbeCommand.probeTempRoot`, `StdlibDupCommand.stdlibDupWorkDir` and
 * `CliFixture.tempDir` each spelled it differently (`?? '/tmp'` against a
 * `length > 0` guard, `TMPDIR` alone against `TMPDIR`-then-`TEMP`, with and without
 * the trailing-slash trim macOS's own `TMPDIR` needs).
 *
 * The two halves answer two different questions and neither substitutes for the
 * other, which is the whole lesson of T700 (S170):
 *
 *  - `root` answers the CALLER's isolation. The suite's private scratch root
 *    (`CliFixture.isolateTempDir`) is a `TMPDIR` it exports, so everything resolved
 *    through here lands inside it and is reaped with it.
 *  - `processToken` answers CONCURRENCY, and it is the half that is easy to think
 *    redundant. `$TMPDIR` is SHARED between workers — on macOS every process of one
 *    user inherits the same `/var/folders/…/T` (verified: it equals
 *    `getconf DARWIN_USER_TEMP_DIR`), and no worker in this campaign sets its own —
 *    so a temp-root base separates nothing between two agents on one machine. Only
 *    the process token does.
 *
 * `root` is a FUNCTION and must stay one: `TMPDIR` is mutated at runtime
 * (`CliFixture.isolateTempDir` exports the run's private root, fixtures stash and
 * restore it), so a cached root would answer with the ambient temp dir the suite
 * exists to stay out of. The process token is the opposite — a pid does not change
 * — so it is resolved once and reused, which is also what makes a slot SINGLE per
 * process rather than per call.
 */
@:nullSafety(Strict)
final class TempScratch {

	#if (sys || nodejs)
	/** The env vars naming the temp root, in the order node itself reads them on POSIX. */
	private static final ROOT_VARS: Array<String> = ['TMPDIR', 'TMP', 'TEMP'];

	/** Where a POSIX host has a temp root when it names none. */
	private static inline final DEFAULT_ROOT: String = '/tmp';

	/** Lowest six-digit value, so the non-node process token is always six characters. */
	private static inline final PROCESS_TOKEN_LOW: Int = 100000;

	/** How many six-digit values that token draws from. */
	private static inline final PROCESS_TOKEN_SPAN: Int = 900000;

	/**
	 * This process's identity inside a scratch name, resolved once.
	 *
	 * Once rather than per call because a slot has to be the SAME file for the whole
	 * process — `apq probe` stages to it and the next command reads it back — while
	 * still differing from another process's. A pid satisfies both; a fresh draw per
	 * call would satisfy only the second — and that was a live defect, not a hypothetical:
	 * the copy this replaced drew inside `processToken()` itself, so on a sys-non-node
	 * target two calls to `ProbeCommand.stageProbePath()` in ONE process named two
	 * different files and the chained `strip` looked at neither.
	 */
	private static final PROCESS_TOKEN: String = resolveProcessToken();

	/**
	 * The OS temp root: `os.tmpdir()` on node, else `$TMPDIR`, `$TMP`, `$TEMP`, `/tmp` —
	 * node's own POSIX order, so the two branches agree on every POSIX host. They do NOT
	 * agree on Windows, where node reads `TEMP` before `TMP` and never reads `TMPDIR`; no
	 * build here targets it.
	 *
	 * Trailing slashes are trimmed because macOS exports `TMPDIR` with one and every
	 * caller joins a name onto the result. A root that is nothing BUT slashes trims to the
	 * empty string, which `Path.join` DROPS — the slot would then be relative and stage
	 * into the process cwd — so that answers the root instead.
	 */
	public static function root(): String {
		#if nodejs
		return js.node.Os.tmpdir();
		#else
		for (name in ROOT_VARS) {
			final value: Null<String> = Sys.getEnv(name);
			if (value != null && value.length > 0) return trimmed(value);
		}
		return DEFAULT_ROOT;
		#end
	}

	/**
	 * `<temp root>/<stem>.<process token><suffix>` — the scratch name a command owns
	 * for the length of its run. The suffix is the extension a FILE slot wants; a
	 * directory takes the default.
	 */
	public static function slot(stem: String, suffix: String = ''): String {
		return Path.join([root(), '$stem.$PROCESS_TOKEN$suffix']);
	}

	/** `path` without its trailing slashes, except that an all-slash root stays the root. */
	private static function trimmed(path: String): String {
		final cut: String = Path.removeTrailingSlashes(path);
		return cut.length > 0 ? cut : DEFAULT_ROOT;
	}

	private static function resolveProcessToken(): String {
		// No portable pid outside node, and no CLI runner outside it either — a draw
		// keeps two processes apart on a target that never reaches here.
		return #if nodejs '${js.Node.process.pid}' #else '${PROCESS_TOKEN_LOW + Std.random(PROCESS_TOKEN_SPAN)}' #end;
	}
	#end

}

package anyparse.query;

import anyparse.core.EnvFlag;
#if nodejs
import js.node.ChildProcess.ChildProcessSpawnSyncResult;
#end

using StringTools;

#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * Discovers the installed Haxe standard-library `std` directory, so the lint
 * resolution scope AND the std-derived tables share ONE auto-discovered channel
 * instead of hardcoded, machine-specific paths. Priority, first existing hit wins:
 *
 *  1. the `HAXE_STD_PATH` environment variable;
 *  2. the `../std` sibling of the real `haxe` binary (`which haxe`, symlinks resolved);
 *  3. the known install locations (`/usr/local/lib/haxe/std`, `/opt/homebrew/lib/haxe/std`).
 *
 * `APQ_NO_STD` (any value but empty or `0`) DECLINES the whole channel before any of
 * that runs — the process-wide opt-out for a project targeting a different Haxe
 * version, mirrored per-project by the `apqlint.json` `resolutionStd: false` key.
 * Without one of the two there is NO way to refuse: step 3 finds a std on any
 * Haxe-equipped machine however `HAXE_STD_PATH` and `PATH` are set.
 *
 * The result is CACHED per process (`stdDir` computes once; `resetCache` is the
 * test-only seam) and null when nothing is found or the std was declined — every
 * consumer then degrades to its pre-existing behaviour: the resolution scope stays
 * inert, and the derivable tables fall back to their hardcoded constants.
 *
 * Beyond discovery, `isStdFile` answers the ORIGIN question for an already-indexed path
 * ("did the std contribute this file?") off the same cached root, so a consumer that must
 * treat std sources differently keys off this channel instead of inspecting path strings.
 * It is STRICTER than `stdDir` by one check (`isStdRoot`): attribution is the only direction
 * in which a wrongly discovered root could shrink a consumer's scan rather than widen it.
 *
 * The impure edges (env read, `which haxe` spawn, symlink + existence checks) live in
 * `stdDir`; the priority logic is the PURE `discover`, unit-tested with a fixture
 * `exists` predicate and no real std. Mirrors `HaxelibResolver`'s pure-assembly split.
 */
@:nullSafety(Strict)
final class StdResolver {

	/** Known Haxe install prefixes whose `std` is probed last — after `HAXE_STD_PATH` and the `which haxe` sibling. */
	public static final KNOWN_LOCATIONS: Array<String> = ['/usr/local/lib/haxe/std', '/opt/homebrew/lib/haxe/std'];

	/** Impure discoveries that actually ran the lookup — a cached hit leaves this untouched (the caching-invariant tests read it). */
	public static var discoveries(default, null): Int = 0;

	/**
	 * The toplevel file every Haxe std ships — the marker `isStdFile` checks before ATTRIBUTING a
	 * path to std, so a `HAXE_STD_PATH` aimed at something else cannot lend its name to a tree.
	 */
	private static inline final STD_MARKER: String = 'Std.hx';

	/** The memoised `stdDir` result; `_computed` distinguishes a cached null from "not yet computed". */
	private static var _cached: Null<String> = null;

	private static var _computed: Bool = false;

	/** The root `isStdRoot` last answered for, and its verdict — one existence check per root per process. */
	private static var _markerRoot: Null<String> = null;

	private static var _markerVerdict: Bool = false;

	/**
	 * The absolute Haxe `std` directory, discovered ONCE and cached, or null when it cannot
	 * be found OR this process DECLINED it via `APQ_NO_STD` — every consumer then keeps its
	 * pre-existing behaviour. Reads `HAXE_STD_PATH`, the `which haxe` sibling and the known
	 * locations through the real filesystem, then defers the priority decision to the pure
	 * `discover`.
	 */
	public static function stdDir(): Null<String> {
		if (_computed) return _cached;
		_computed = true;
		discoveries++;
		_cached = declined() ? null : discover(envStd(), whichHaxeSiblingStd(), KNOWN_LOCATIONS, dirExists);
		return _cached;
	}

	/**
	 * TEST-ONLY seam: drop the memoised `stdDir` result so the next call re-discovers. The
	 * process-wide memo is what would otherwise make `APQ_NO_STD` untestable in a
	 * single-process suite — a test that toggles it must reset on both sides, so the rest of
	 * the suite keeps the real std.
	 */
	public static function resetCache(): Void {
		_cached = null;
		_computed = false;
		_markerRoot = null;
		_markerVerdict = false;
	}

	/**
	 * PURE priority resolution: the first of `env`, `whichSiblingStd`, then each `known`
	 * location that `exists` as a directory — normalised — or null when none does. No
	 * I/O (the `exists` predicate is injected), so the fallback order is unit-testable
	 * against a fixture tree without a real std. A set-but-nonexistent hint (a stale
	 * `HAXE_STD_PATH`) is skipped, not fatal — the next candidate answers.
	 */
	public static function discover(
		env: Null<String>, whichSiblingStd: Null<String>, known: Array<String>, exists: (String) -> Bool
	): Null<String> {
		final candidates: Array<Null<String>> = [env, whichSiblingStd];
		for (k in known) candidates.push(k);
		for (c in candidates) if (c != null) {
			final path: String = haxe.io.Path.normalize(c);
			if (exists(path)) return path;
		}
		return null;
	}

	/**
	 * The resolution-scope specs a discovered `stdDir` contributes, in the shape
	 * `expandInputs` consumes: the toplevel `*.hx` glob plus the `haxe/` and `sys/`
	 * subtree directories — the target-agnostic core, excluding the target-specific
	 * subtrees (`js/`, `cpp/`, `python/`, …). Pure — no I/O.
	 */
	public static function resolutionSpecs(stdDir: String): Array<String> {
		return [
			haxe.io.Path.join([stdDir, '*.hx']),
			haxe.io.Path.join([stdDir, 'haxe']),
			haxe.io.Path.join([stdDir, 'sys'])
		];
	}

	/**
	 * Whether `path` names a file the auto-discovered std contributed to the resolution scope
	 * — the ORIGIN marker for a consumer whose proof holds inside std but not outside it.
	 * Answered against the SAME memoised `stdDir` the scope was built from, so there is one
	 * notion of "this came from std" and no guessing at a `/std/` path segment.
	 *
	 * False whenever the channel is declined or absent (`APQ_NO_STD`, `"resolutionStd": false`,
	 * no Haxe on the machine): with no std root there is nothing to attribute, and a consumer
	 * that excludes std files then excludes none. That is the fail-closed direction — the only
	 * answer that could WEAKEN such a consumer's proof is a project file misread as std, which
	 * is what `isStdRoot` exists to prevent.
	 */
	public static function isStdFile(path: String): Bool {
		final dir: Null<String> = stdDir();
		return dir != null && isStdRoot(dir) && isUnder(dir, path);
	}

	/**
	 * PURE containment test: whether `path` lies strictly inside directory `dir`, both
	 * normalised (backslashes folded, `.` / `..` resolved). The separator after `dir` is
	 * required, so a sibling whose name merely starts with it (`/a/std-old/x.hx` against
	 * `/a/std`) is outside. A RELATIVE `path` can never be inside an absolute `dir` and answers
	 * false — which is what report files, spelled the way the CLI received them, get, and the
	 * direction that keeps them inside a std-excluding consumer's scan.
	 */
	public static function isUnder(dir: String, path: String): Bool {
		final root: String = haxe.io.Path.removeTrailingSlashes(haxe.io.Path.normalize(dir));
		return root != '' && StringTools.startsWith(haxe.io.Path.normalize(path), '$root/');
	}

	/**
	 * Whether `APQ_NO_STD` DECLINES the auto-discovered std: set to anything other than the
	 * empty string or `0`. The env twin of the `apqlint.json` `resolutionStd: false` key, and
	 * the only way to refuse the std on a machine where `KNOWN_LOCATIONS` finds one whatever
	 * `HAXE_STD_PATH` and `PATH` say. It cuts the WHOLE channel — the implicit resolution
	 * scope and the std-derived tables alike — so `Cli.resolutionThunk`'s null branch and the
	 * table-only fallbacks stay reachable on a Haxe-equipped box instead of being dead in CI.
	 */
	private static function declined(): Bool return EnvFlag.isSet('APQ_NO_STD');

	/**
	 * Whether `dir` really IS a Haxe std — it carries the toplevel `Std.hx` every std ships —
	 * rather than merely whatever `HAXE_STD_PATH` happened to name. Memoised per root, so the
	 * existence check runs once per process for the one root `stdDir` ever returns.
	 *
	 * `stdDir` itself accepts any existing directory on purpose: for its other consumers a wrong
	 * root only WIDENS the resolution scope or falls back to a hardcoded table, both harmless.
	 * The origin question inverts that. A `HAXE_STD_PATH` pointed at a project tree would let
	 * that project's own files be attributed to std, and a consumer that EXCLUDES std files
	 * would then skip real project code — the one direction in which this channel can weaken a
	 * proof. So the stricter question gets its own gate here instead of tightening `stdDir`,
	 * whose laxity is load-bearing elsewhere.
	 */
	private static function isStdRoot(dir: String): Bool {
		if (_markerRoot == dir) return _markerVerdict;
		_markerRoot = dir;
		#if (sys || nodejs)
		_markerVerdict = FileSystem.exists(haxe.io.Path.join([dir, STD_MARKER]));
		#else
		_markerVerdict = false;
		#end
		return _markerVerdict;
	}

	/** The `HAXE_STD_PATH` environment variable, trimmed, or null when unset/blank. */
	private static function envStd(): Null<String> {
		#if (sys || nodejs)
		final v: Null<String> = Sys.getEnv('HAXE_STD_PATH');
		if (v == null) return null;
		final trimmed: String = StringTools.trim(v);
		return trimmed == '' ? null : trimmed;
		#else
		return null;
		#end
	}

	/**
	 * The `../std` sibling of the real `haxe` binary: `which haxe`, then the binary's
	 * symlink chain resolved, then its directory's `../std`, normalised. Null on any
	 * failure (no `haxe` on PATH, a non-zero exit). Homebrew keeps std under
	 * `lib/haxe/std` (not `../std`), so this misses there and the known-location
	 * fallback answers — by design, not a bug.
	 */
	private static function whichHaxeSiblingStd(): Null<String> {
		final bin: Null<String> = whichHaxe();
		if (bin == null) return null;
		final real: String = resolveSymlink(bin);
		return haxe.io.Path.normalize(haxe.io.Path.join([haxe.io.Path.directory(real), '..', 'std']));
	}

	/** Spawn `which haxe` and return its trimmed stdout on a zero exit, or null on any failure (mirrors `HaxelibResolver.runLibpath`). */
	private static function whichHaxe(): Null<String> {
		#if nodejs
		final res: ChildProcessSpawnSyncResult = js.node.ChildProcess.spawnSync('which', ['haxe'], { encoding: 'utf8' });
		final launchError: Null<Dynamic> = (res.error: Dynamic);
		if (launchError != null) return null;
		final status: Null<Int> = (res.status: Null<Int>);
		if (status == null || status != 0) return null;
		final out: Dynamic = res.stdout;
		final s: Null<String> = out == null ? null : '$out'.trim();
		return s == null || s == '' ? null : s;
		#elseif sys
		try {
			final process: sys.io.Process = new sys.io.Process('which', ['haxe']);
			final out: String = process.stdout.readAll().toString();
			// `exitCode()` is `Null<Int>`: null only in the non-blocking form, which this
			// call is not; a null still means "no status", so it falls through to null like
			// the nodejs branch's `status == null` arm.
			final code: Null<Int> = process.exitCode();
			process.close();
			final s: String = out.trim();
			return code == 0 && s != '' ? s : null;
		} catch (exception: haxe.Exception) {
			return null;
		}
		#else
		return null;
		#end
	}

	/** Resolve a symlink chain to its canonical target; the input path on any failure (an unreadable / broken link degrades gracefully). */
	private static function resolveSymlink(path: String): String {
		#if (sys || nodejs)
		// `FileSystem.fullPath` is DECLARED to return a non-null `String`, but a module restored
		// from a compilation-server cache has that read as nullable, and the mismatch surfaces as
		// a null-safety error on warm compiles only. Bridging the result explicitly makes the
		// function correct under either reading instead of only the fresh-compile one.
		final full: Null<String> = try FileSystem.fullPath(path) catch (exception: haxe.Exception) null;
		return full ?? path;
		#else
		return path;
		#end
	}

	/** Whether `path` exists AND is a directory — the injected `exists` predicate for the real filesystem. */
	private static function dirExists(path: String): Bool {
		#if (sys || nodejs)
		return FileSystem.exists(path) && FileSystem.isDirectory(path);
		#else
		return false;
		#end
	}

}

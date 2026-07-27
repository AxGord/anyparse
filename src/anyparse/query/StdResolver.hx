package anyparse.query;

import haxe.Exception;
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

	/** The memoised `stdDir` result; `_computed` distinguishes a cached null from "not yet computed". */
	private static var _cached: Null<String> = null;

	private static var _computed: Bool = false;

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
	}

	/**
	 * Whether `APQ_NO_STD` DECLINES the auto-discovered std: set to anything other than the
	 * empty string or `0`. The env twin of the `apqlint.json` `resolutionStd: false` key, and
	 * the only way to refuse the std on a machine where `KNOWN_LOCATIONS` finds one whatever
	 * `HAXE_STD_PATH` and `PATH` say. It cuts the WHOLE channel — the implicit resolution
	 * scope and the std-derived tables alike — so `Cli.resolutionThunk`'s null branch and the
	 * table-only fallbacks stay reachable on a Haxe-equipped box instead of being dead in CI.
	 */
	private static function declined(): Bool {
		#if (sys || nodejs)
		final raw: Null<String> = Sys.getEnv('APQ_NO_STD');
		if (raw == null) return false;
		final trimmed: String = StringTools.trim(raw);
		return trimmed != '' && trimmed != '0';
		#else
		return false;
		#end
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
		final res = js.node.ChildProcess.spawnSync('which', ['haxe'], { encoding: 'utf8' });
		final launchError: Null<Dynamic> = (res.error: Dynamic);
		if (launchError != null) return null;
		final status: Null<Int> = (res.status: Null<Int>);
		if (status == null || status != 0) return null;
		final out: Dynamic = res.stdout;
		final s: Null<String> = out == null ? null : StringTools.trim(Std.string(out));
		return s == null || s == '' ? null : s;
		#elseif sys
		try {
			final process: sys.io.Process = new sys.io.Process('which', ['haxe']);
			final out: String = process.stdout.readAll().toString();
			final code: Int = process.exitCode();
			process.close();
			final s: String = StringTools.trim(out);
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
		return try FileSystem.fullPath(path) catch (exception: haxe.Exception) path;
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

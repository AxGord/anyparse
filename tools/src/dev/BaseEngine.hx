package dev;

import devkit.Args;
import devkit.Cmd.cmd;
import devkit.Result;
import devkit.TempDir;
import haxe.Exception;
import haxe.crypto.Sha256;
import haxe.io.Path;
import js.node.Fs.Fs;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * `dev base-engine <commit> [--repo <tree>] [--cache <dir>]` — the `apq.js` engine a commit builds, printed as a path. The
 * whole commit is copied out with `git archive` into a run-scoped scratch directory and built there (a macro may read any file
 * of the tree, not only the classpath); the engine
 * is kept in a cache under the full commit hash with its checksum and the compiler that built it, so a series of reviews
 * against one base builds it once. An entry whose checksum or compiler no longer matches is rebuilt, never used.
 */
@:nullSafety(Strict)
final class BaseEngine {

	public static inline final USAGE: String = 'usage: dev base-engine <commit> [--repo <tree>] [--cache <dir>]';

	/** Days an entry no run has used is kept, unless `BASE_ENGINE_MAX_AGE_DAYS` says otherwise. */
	public static inline final MAX_AGE_DAYS: Int = 7;

	/** The engine's file name inside a cache entry. */
	public static inline final ENGINE: String = 'apq.js';

	/** The file holding the SHA-256 of the engine, written once the build succeeded. */
	private static inline final CHECKSUM: String = 'apq.js.sha256';

	/** The file naming the compiler that built the engine. */
	private static inline final TOOLCHAIN: String = 'toolchain';

	/** The build file of the engine alone, without the code-cache launcher the shared build adds. */
	private static inline final HXML: String = 'bin/apq-js-common.hxml';

	private static inline final SECONDS_PER_DAY: Float = 86400;
	private static inline final MS_PER_SECOND: Float = 1000;

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final repo: String = Repo.resolve(args.option('--repo'));
		final cache: String = args.option('--cache') ?? defaultCache();
		final commit: String = args.positionals(['<commit>'])[0];
		Sys.println(forCommit(repo, commit, cache));
		return 0;
	}

	/** The engine of `commit` (any revision `git rev-parse` reads in `repo`), from `cache` or built into it; prunes `cache` first. */
	public static function forCommit(repo: String, commit: String, cache: String): String {
		final resolved: Result = cmd('git -C $repo rev-parse --verify --quiet $commit^{commit}').run();
		if (!resolved.ok) throw new UsageError('$commit names no commit in $repo');
		final full: String = resolved.out.trim();
		prune(cache, maxAgeDays());
		return ensure(cache, full, toolchain(), out -> build(repo, full, out));
	}

	/**
	 * The engine of `key` in `cache`: the kept one when it is `valid` for `stamp`, else one `build` writes into a fresh staging
	 * directory, which is moved into place whole once its checksum is written — so a reader never sees a half-built entry, and of
	 * two runs building one key at once the first to move wins and the other discards its own.
	 */
	public static function ensure(cache: String, key: String, stamp: String, build: String -> Void): String {
		final entry: String = Path.join([cache, key]);
		final engine: String = Path.join([entry, ENGINE]);
		if (valid(entry, stamp)) {
			final now: Date = Date.now();
			Fs.utimesSync(entry, now, now);
			return engine;
		}
		FileSystem.createDirectory(cache);
		remove(entry);
		final staging: String = '$entry.${js.Node.process.pid}.tmp';
		remove(staging);
		FileSystem.createDirectory(staging);
		try {
			build(staging);
			File.saveContent(Path.join([staging, CHECKSUM]), digest(Path.join([staging, ENGINE])));
			File.saveContent(Path.join([staging, TOOLCHAIN]), stamp);
			FileSystem.rename(staging, entry);
		} catch (exception: Exception) {
			remove(staging);
			if (!valid(entry, stamp)) throw exception;
		}
		return engine;
	}

	/** Whether the cache entry `entry` holds an engine whose content matches its checksum, built by the compiler `stamp` names. */
	public static function valid(entry: String, stamp: String): Bool {
		final engine: String = Path.join([entry, ENGINE]);
		final checksum: String = Path.join([entry, CHECKSUM]);
		final toolchain: String = Path.join([entry, TOOLCHAIN]);
		return FileSystem.exists(engine)
			&& FileSystem.exists(checksum)
			&& FileSystem.exists(toolchain)
			&& File.getContent(toolchain) == stamp
			&& File.getContent(checksum) == digest(engine);
	}

	/** Build the engine of `commit` of `repo` into the directory `out`, from a copy of the commit's sources. */
	public static function build(repo: String, commit: String, out: String): Void {
		TempDir.with(dir -> {
			final copy: String = dir.file('tree');
			final archive: String = dir.file('tree.tar');
			FileSystem.createDirectory(copy);
			cmd('git -C $repo archive --format=tar -o $archive $commit').check();
			cmd('tar -xf $archive -C $copy').check();
			if (!FileSystem.exists(Path.join([copy, HXML]))) throw new Exception('$commit has no $HXML to build its engine with');
			final run: Result = cmd('haxe $HXML -js ${Path.join([out, ENGINE])}').at(copy).run();
			if (!run.ok) throw new Exception('the engine of $commit does not build: ${run.firstError()}');
		});
	}

	/** Remove every entry of `cache` (a killed run's staging directory included) no run has used for more than `days` whole days. */
	public static function prune(cache: String, days: Int): Void {
		if (!FileSystem.exists(cache) || !FileSystem.isDirectory(cache)) return;
		final now: Float = Sys.time();
		for (name in FileSystem.readDirectory(cache)) {
			final path: String = Path.join([cache, name]);
			final mtime: Null<Float> = try Fs.lstatSync(path).mtime.getTime() / MS_PER_SECOND catch (exception: Exception) null;
			if (mtime != null && Math.floor((now - mtime) / SECONDS_PER_DAY) > days) remove(path);
		}
	}

	/** The cache the engines are kept in when the caller names none. */
	public static function defaultCache(): String {
		return Path.join([anyparse.core.TempScratch.root(), 'anyparse-base-engine']);
	}

	/** The age limit the environment gives (`BASE_ENGINE_MAX_AGE_DAYS`). */
	public static function maxAgeDays(): Int {
		return Std.parseInt(Sys.getEnv('BASE_ENGINE_MAX_AGE_DAYS') ?? '') ?? MAX_AGE_DAYS;
	}

	private static inline function remove(path: String): Void {
		js.Syntax.code("require('fs').rmSync({0}, { recursive: true, force: true })", path);
	}

	/** The compiler an engine is built by, as `haxe -version` names it. */
	private static function toolchain(): String {
		final version: Result = cmd('haxe -version').check();
		return (version.out + version.err).trim();
	}

	private static function digest(file: String): String {
		return Sha256.make(File.getBytes(file)).toHex();
	}

}

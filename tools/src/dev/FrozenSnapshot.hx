package dev;

import devkit.Cmd.cmd;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;

using StringTools;

/**
 * The one answer to "which directory does a slice gate read as the downstream tree no slice may write, so that the work its
 * owner does in the live checkout never reaches a gate": a copy of the live tree's committed HEAD, taken with `git archive`
 * (nothing is written into the live repository) into a cache every gate on this machine shares, one entry per commit. The
 * live tree's uncommitted edits and untracked files are not in it; a commit made in the live tree is a new entry, never a
 * change of an old one. A baseline records the snapshot's directory and digest, and the `frozen` row compares that directory
 * again, never the live tree.
 */
@:nullSafety(Strict)
final class FrozenSnapshot {

	/** The environment variable that names the cache directory instead of the default. */
	public static final CACHE_VAR: String = 'SLICE_FROZEN_CACHE';

	/** The cache the snapshots are kept in when the caller names none. */
	public static inline function defaultCache(): String {
		return BaseBranch.cachePath(CACHE_VAR, 'anyparse-slice-frozen');
	}

	/** What a baseline records for `live`: the snapshot of its HEAD in `cache` and that snapshot's digest. */
	public static function record(cache: String, live: String): FrozenTree {
		final dir: String = take(cache, live);
		return { dir: dir, digest: digest(dir) };
	}

	/** The directory holding the committed HEAD of the git work tree `live`, made on first use and marked as used on every one. */
	public static function take(cache: String, live: String): String {
		final head: String = GateTree.gitIn(live, ['rev-parse', 'HEAD']).trim();
		BaseEngine.keep(
			cache, head, staging -> TempDir.with(scratch -> {
				final archive: String = scratch.file('tree.tar');
				cmd('git -C $live archive --format=tar -o $archive $head').check();
				cmd('tar -xf $archive -C $staging').check();
			})
		);
		final entry: String = Path.join([cache, head]);
		BaseEngine.touch(entry);
		return entry;
	}

	/**
	 * The digest the `frozen` row compares: of a snapshot, its files' paths, sizes and modification times; of a directory that
	 * is itself a git work tree (a record made before snapshots existed), its `git diff`; of a directory gone, a word no
	 * digest equals.
	 */
	public static function digest(dir: String): String {
		if (!FileSystem.exists(dir)) return 'missing';
		return FileSystem.exists(Path.join([dir, '.git'])) ? GateTree.diffDigest(dir) : GateTree.treeState(dir);
	}

}

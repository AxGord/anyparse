package dev;

import devkit.Cmd.cmd;
import devkit.Result;
import haxe.io.Path;
import sys.FileSystem;

using Lambda;
using StringTools;

/**
 * The one answer to "which paths does no test read, so that a main commit changing only them leaves a landing's judgment
 * standing": the base snapshot of such a main is the snapshot of an ancestor, and `advance` follows such a main instead of
 * refusing it. A path is added only after every test was read for it (`TolerantPathsHonestyTest` holds the list to that); a
 * directory is spelled with its trailing slash.
 */
@:nullSafety(Strict)
final class TolerantPaths {

	/** The paths, a directory by its trailing slash. */
	public static final PATHS: Array<String> = ['docs/decisions.md', 'docs/journal/'];

	/** How many first-parent ancestors a snapshot is looked for in. */
	private static inline final DEPTH: Int = 30;

	/** Whether `path` is one of the tolerated paths or lies under a tolerated directory. */
	public static function covers(path: String): Bool {
		return PATHS.exists(tolerated -> path == tolerated || (tolerated.endsWith('/') && path.startsWith(tolerated)));
	}

	/** Whether `paths` names something and nothing outside the tolerated paths: a change of no file is no tolerated change. */
	public static function inside(paths: Array<String>): Bool {
		return paths.length != 0 && paths.foreach(covers);
	}

	/** Whether the tree at `to` differs from the tree at `from` in tolerated paths alone, and in at least one. */
	public static function onlyBetween(repo: String, from: String, to: String): Bool {
		final diff: Result = cmd('git -C $repo diff --name-only --no-renames $from $to').run();
		return diff.ok && inside(diff.lines());
	}

	/** Whether `older` is an ancestor of `newer`. */
	public static function ancestor(repo: String, older: String, newer: String): Bool {
		return cmd('git -C $repo merge-base --is-ancestor $older $newer').run().ok;
	}

	/**
	 * The key of the nearest first-parent ancestor of `head` that has a snapshot in `cache` and differs from `head` in
	 * tolerated paths alone, or null; the walk stops at the first ancestor that differs elsewhere.
	 */
	public static function snapshotBefore(repo: String, head: String, cache: String): Null<String> {
		final walked: Result = cmd('git -C $repo rev-list --first-parent --max-count=${DEPTH + 1} $head').run();
		if (!walked.ok) return null;
		for (ancestor in walked.lines().slice(1)) {
			if (!onlyBetween(repo, ancestor, head)) return null;
			final key: Null<String> = Battery.keyOf(repo, ancestor);
			if (key != null && FileSystem.exists(Path.join([cache, '$key-suite.txt']))) return key;
		}
		return null;
	}

}

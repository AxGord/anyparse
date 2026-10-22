package dev;

import haxe.io.Path;
import sys.FileSystem;

/**
 * The tree a developer tool works on when the caller names none: the one holding the running `bin/dev.js` — never the
 * working directory, so a copy built inside a worktree acts on THAT worktree, the way each `tools/*.sh` resolved its
 * repository from its own location.
 */
@:nullSafety(Strict)
final class Repo {

	/** The file that marks a directory as this project's tree. */
	private static inline final MARKER: String = 'tools/dev.hxml';

	/** The tree whose `bin/` holds the running script, or null when the script was built anywhere else. */
	public static function ofScript(): Null<String> {
		final script: String = FileSystem.fullPath(js.Node.__filename);
		final tree: String = Path.directory(Path.directory(script));
		return FileSystem.exists(Path.join([tree, MARKER])) ? tree : null;
	}

	/** `given` when the caller named a tree (as an absolute path), else the script's own; throws when there is neither. */
	public static function resolve(given: Null<String>): String {
		if (given != null) return FileSystem.fullPath(given);
		final own: Null<String> = ofScript();
		if (own == null) throw new devkit.Args.UsageError('this dev.js does not sit in a tree\'s bin/ — name the tree with --repo');
		return own;
	}

}

package unit;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * Fresh fixture directories under the system temp, for a test whose subject reads a config it DISCOVERS from a
 * file's path (`hxformat.json`, `apqlint.json`): no ancestor of a tree holds either, so the fixture's own config is
 * the one read. Every tree `make` built is deleted by `removeAll` - call it from `teardown`; the shared parent
 * directory is reused across runs. Each tree is uniquely named, so a per-directory discovery cache never answers
 * one fixture from another's config.
 */
@:nullSafety(Strict)
final class ConfigTrees {

	/** Every tree `make` built and `removeAll` has not removed yet. */
	private final _made: Array<String> = [];

	/** The directory every tree of this suite is built under. */
	private final _root: String;

	/** `suite` names the shared parent directory under the system temp. */
	public function new(suite: String) {
		_root = Path.join([Sys.getEnv('TMPDIR') ?? '/tmp', suite]);
	}

	/** A fresh, uniquely named, empty directory whose name starts with `name`. */
	public function make(name: String): String {
		if (!FileSystem.exists(_root)) FileSystem.createDirectory(_root);
		final dir: String = Path.join([_root, '$name-${Std.random(0x7FFFFFFF)}']);
		FileSystem.createDirectory(dir);
		_made.push(dir);
		return dir;
	}

	/** A fresh tree holding `hxformat.json` with `config`; answers the tree. */
	public function withFormatConfig(name: String, config: String): String {
		final dir: String = make(name);
		File.saveContent(Path.join([dir, 'hxformat.json']), config);
		return dir;
	}

	/** Delete every tree `make` built. */
	public function removeAll(): Void {
		for (dir in _made) removeTree(dir);
		_made.resize(0);
	}

	/** `dir` and everything under it, deleted. */
	private static function removeTree(dir: String): Void {
		if (!FileSystem.exists(dir)) return;
		for (entry in FileSystem.readDirectory(dir)) {
			final path: String = Path.join([dir, entry]);
			if (FileSystem.isDirectory(path))
				removeTree(path);
			else
				FileSystem.deleteFile(path);
		}
		FileSystem.deleteDirectory(dir);
	}

}

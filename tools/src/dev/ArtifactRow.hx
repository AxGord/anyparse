package dev;

import haxe.io.Path;
import sys.FileSystem;

/**
 * The one answer to "which files a slice changed are build output or too big to commit": the slice gate's `artifacts`
 * row. A file is an offender when it is over `MAX_BYTES`, sits under `out/` or `dist/`, is a built script or code cache
 * (`.js`, `.v8cache`, `.map`), or sits under `bin/` as anything but a Haxe build file or an extensionless shim. A path
 * named by `--allow` is let through; `--allow artifacts` lets the whole row through.
 */
@:nullSafety(Strict)
final class ArtifactRow {

	/** The size past which a committed file is a build output until a gate's caller says otherwise. */
	public static inline final MAX_BYTES: Int = 1024 * 1024;

	private static final OUTPUT_EXTENSIONS: Array<String> = ['js', 'v8cache', 'map'];
	private static final OUTPUT_DIRECTORIES: Array<String> = ['out', 'dist'];

	/** Why `path` of `size` bytes is not committable, or null when it is. */
	public static function problem(path: String, size: Int): Null<String> {
		final segments: Array<String> = path.split('/');
		final extension: String = Path.extension(path);
		if (size > MAX_BYTES) return 'over 1 MB ($size bytes)';
		if (OUTPUT_DIRECTORIES.contains(segments[0])) return 'build output directory ${segments[0]}/';
		if (OUTPUT_EXTENSIONS.contains(extension)) return 'build output .$extension';
		if (segments[0] == 'bin' && extension != '' && extension != 'hxml') return 'build output under bin/';
		return null;
	}

	/** The offenders among `files` (paths in the tree `tree`) that `allow` does not name, each `path: reason`. */
	public static function offenders(tree: String, files: Array<String>, allow: Array<String>): Array<String> {
		final found: Array<String> = [];
		for (file in files) if (!allow.contains(file)) {
			final full: String = Path.join([tree, file]);
			if (!FileSystem.exists(full) || FileSystem.isDirectory(full)) continue;
			final why: Null<String> = problem(file, FileSystem.stat(full).size);
			if (why != null) found.push('$file: $why');
		}
		return found;
	}

}

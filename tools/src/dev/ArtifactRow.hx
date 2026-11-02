package dev;

import devkit.Cmd.cmd;
import devkit.Result;
import haxe.io.Path;
import sys.FileSystem;

using StringTools;

/**
 * The one answer to "which files a slice changed are build output or too big to commit": the slice gate's `artifacts`
 * row. A file is an offender when it is over `MAX_BYTES` and the branch adds it, makes it cross that size, or grows an
 * already-large file by more than `MAX_GROWTH_PERCENT`; or when it sits under `out/` or `dist/`, is a built script or code cache
 * (`.js`, `.v8cache`, `.map`), or sits under `bin/` as anything but a Haxe build file or an extensionless shim. A path
 * named by `--allow` is let through; `--allow artifacts` lets the whole row through.
 */
@:nullSafety(Strict)
final class ArtifactRow {

	/** The size past which a committed file is a build output until a gate's caller says otherwise. */
	public static inline final MAX_BYTES: Int = 1024 * 1024;

	/** How far an already-large tracked file may grow in one branch, in percent of its size at the base. */
	public static inline final MAX_GROWTH_PERCENT: Int = 25;

	private static inline final PERCENT: Int = 100;
	private static final OUTPUT_EXTENSIONS: Array<String> = ['js', 'v8cache', 'map'];
	private static final OUTPUT_DIRECTORIES: Array<String> = ['out', 'dist'];

	/** Why `path` of `size` bytes (`baseSize` at the base, null when absent there) is not committable, or null when it is. */
	public static function problem(path: String, size: Int, ?baseSize: Int): Null<String> {
		final segments: Array<String> = path.split('/');
		final extension: String = Path.extension(path);
		if (size > MAX_BYTES) {
			if (baseSize == null) return 'over 1 MB ($size bytes), added';
			if (baseSize <= MAX_BYTES) return 'over 1 MB ($size bytes), crossed from $baseSize';
			if (size * PERCENT > baseSize * (PERCENT + MAX_GROWTH_PERCENT))
				return 'grew over $MAX_GROWTH_PERCENT% ($baseSize -> $size bytes)';
		}
		if (OUTPUT_DIRECTORIES.contains(segments[0])) return 'build output directory ${segments[0]}/';
		if (OUTPUT_EXTENSIONS.contains(extension)) return 'build output .$extension';
		if (segments[0] == 'bin' && extension != '' && extension != 'hxml') return 'build output under bin/';
		return null;
	}

	/**
	 * The offenders among `files` (paths in the tree `tree`) that `allow` does
	 * not name, each `path: reason`; `baseSize` gives a path's size at the base.
	 */
	public static function offenders(
		tree: String, files: Array<String>, allow: Array<String>, baseSize: String -> Null<Int>
	): Array<String> {
		final found: Array<String> = [];
		for (file in files) if (!allow.contains(file)) {
			final full: String = Path.join([tree, file]);
			if (!FileSystem.exists(full) || FileSystem.isDirectory(full)) continue;
			final why: Null<String> = problem(file, FileSystem.stat(full).size, baseSize(file));
			if (why != null) found.push('$file: $why');
		}
		return found;
	}

	/** `offenders` with `baseSize` read from `base` in the git tree `tree`: the one path the slice gate takes. */
	public static function offendersAtBase(tree: String, base: String, files: Array<String>, allow: Array<String>): Array<String> {
		return offenders(tree, files, allow, file -> {
			final size: Result = cmd('git -C $tree cat-file -s $base:$file').run();
			size.ok ? Std.parseInt(size.out.trim()) : null;
		});
	}

}

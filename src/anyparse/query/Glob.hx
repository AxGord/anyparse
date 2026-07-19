package anyparse.query;

#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * Input-path expander for `apq` (`search` / `meta` / `refs`).
 *
 * Supports three forms in a single positional argument:
 *  - A single file path → returns `[path]`.
 *  - A directory path → recursively walks and returns every regular
 *    file whose name ends in `extension` (e.g. `.hx`).
 *  - A glob pattern (star, double-star, `?`, char-class) → translated
 *    to a regex and matched against the recursively-walked file tree.
 *    The literal prefix up to the first glob metacharacter is used as
 *    the walk root, so a single-directory star pattern only scans that
 *    directory while a double-star pattern scans the whole subtree.
 *
 * Glob semantics:
 *  - star matches any run of characters within a path segment (not the
 *    path separator).
 *  - double-star matches across segments; followed by a separator it
 *    additionally matches zero directories.
 *  - `?` matches a single non-separator character.
 *  - `[...]` is a character class; a leading `!` negates it.
 *
 * Targets without filesystem access (no `sys` and no `nodejs`) get an
 * empty result; callers handle the empty case as a configuration /
 * target mismatch.
 */
@:nullSafety(Strict)
final class Glob {

	public static function expand(spec: String, extension: String): Array<String> {
		final out: Array<String> = [];
		#if (sys || nodejs)
		final norm: String = stripTrailingSlash(spec);
		if (isGlob(norm)) {
			final base: String = globBase(norm);
			final re: EReg = globToRegex(norm);
			final fsRoot: String = base == '' ? '.' : base;
			if (FileSystem.exists(fsRoot) && FileSystem.isDirectory(fsRoot)) collectMatching(fsRoot, base, re, out);
		} else if (FileSystem.exists(norm)) {
			if (FileSystem.isDirectory(norm))
				collect(norm, extension, out);
			else
				out.push(norm);
		}
		out.sort((a: String, b: String) -> a < b ? -1 : (a > b ? 1 : 0));
		#end
		return out;
	}

	/**
	 * Strip trailing `/` from a user-supplied path so downstream
	 * `dir + '/' + name` concatenations don't produce `foo//bar`. Keeps
	 * the root `'/'` and a bare `'.'` unchanged.
	 */
	private static function stripTrailingSlash(spec: String): String {
		var end: Int = spec.length;
		while (end > 1 && spec.charAt(end - 1) == '/') end--;
		return end == spec.length ? spec : spec.substr(0, end);
	}

	#if (sys || nodejs)
	private static function collect(dir: String, extension: String, into: Array<String>): Void {
		for (name in FileSystem.readDirectory(dir)) {
			final path: String = '$dir/$name';
			if (FileSystem.isDirectory(path))
				collect(path, extension, into);
			else if (StringTools.endsWith(name, extension))
				into.push(path);
		}
	}

	/**
	 * Recursively walk `fsDir`, accumulating the printable path in
	 * `prefix` (empty when the walk root is the cwd), and keep files
	 * whose printable path fully matches `re`.
	 */
	private static function collectMatching(fsDir: String, prefix: String, re: EReg, into: Array<String>): Void {
		for (name in FileSystem.readDirectory(fsDir)) {
			final fsPath: String = '$fsDir/$name';
			final rel: String = prefix == '' ? name : '$prefix/$name';
			if (FileSystem.isDirectory(fsPath))
				collectMatching(fsPath, rel, re, into);
			else if (re.match(rel))
				into.push(rel);
		}
	}

	private static inline function isGlobChar(c: String): Bool {
		return c == '*' || c == '?' || c == '[';
	}

	private static function isGlob(spec: String): Bool {
		for (i in 0...spec.length) if (isGlobChar(spec.charAt(i))) return true;
		return false;
	}

	/**
	 * Literal directory prefix preceding the first glob metacharacter,
	 * with no trailing slash. `''` when the pattern starts globbing
	 * before any `/` (walk root is the cwd).
	 */
	private static function globBase(spec: String): String {
		var firstGlob: Int = spec.length;
		for (i in 0...spec.length) if (isGlobChar(spec.charAt(i))) {
			firstGlob = i;
			break;
		}
		final lastSlash: Int = spec.substr(0, firstGlob).lastIndexOf('/');
		return lastSlash < 0 ? '' : spec.substr(0, lastSlash);
	}

	/**
	 * Translate a glob pattern to a fully-anchored regex over the
	 * printable path string.
	 */
	private static function globToRegex(spec: String): EReg {
		final buf: StringBuf = new StringBuf();
		buf.add('^');
		var i: Int = 0;
		final n: Int = spec.length;
		while (i < n) {
			final c: String = spec.charAt(i);
			switch c {
				case '*':
					if (i + 1 < n && spec.charAt(i + 1) == '*') {
						// `**` — across segments. `**/` also matches zero dirs.
						if (i + 2 < n && spec.charAt(i + 2) == '/') {
							buf.add('(?:.*/)?');
							i += 3; // noqa: magic-number
						} else {
							buf.add('.*');
							i += 2;
						}
					} else {
						buf.add('[^/]*');
						i++;
					}
				case '?':
					buf.add('[^/]');
					i++;
				case '[':
					final end: Int = spec.indexOf(']', i + 1);
					if (end < 0) {
						// Unterminated class — treat `[` literally.
						buf.add('\\[');
						i++;
					} else {
						buf.add('[');
						final body: String = spec.substr(i + 1, end - i - 1);
						buf.add(StringTools.startsWith(body, '!') ? '^${body.substr(1)}' : body);
						buf.add(']');
						i = end + 1;
					}
				case _:
					if (c != '/' && "\\.+(){}$^|".indexOf(c) >= 0) buf.add('\\');
					buf.add(c);
					i++;
			}
		}
		buf.add('$');
		return new EReg(buf.toString(), '');
	}
	#end

}

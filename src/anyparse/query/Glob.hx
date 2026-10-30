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

	/**
	 * A fully-anchored regex matching the qualified names (`pack.sub.Name`) the glob `spec` describes: star within one
	 * dotted segment, double-star across segments (followed by a dot it also matches none), `?` one character of a
	 * segment, `[...]` a character class.
	 */
	public static inline function qualifiedNames(spec: String): EReg {
		return globToRegex(spec, '.');
	}

	public static function expand(spec: String, extension: String): Array<String> {
		final out: Array<String> = [];
		#if (sys || nodejs)
		final norm: String = stripTrailingSlash(spec);
		if (isGlob(norm)) {
			final base: String = globBase(norm);
			final re: EReg = globToRegex(norm, '/');
			final fsRoot: String = base == '' ? '.' : base;
			if (FileSystem.exists(fsRoot) && FileSystem.isDirectory(fsRoot)) collectMatching(fsRoot, base, re, out);
		} else if (FileSystem.exists(norm)) {
			if (FileSystem.isDirectory(norm))
				collect(norm, extension, out);
			else
				out.push(norm);
		}
		out.sort((a: String, b: String) -> if (a < b)
			-1
		else if (a > b)
			1
		else
			0);
		#end
		return out;
	}

	/**
	 * The paths of `listed` the input `spec` names, as `expand` reads it over a file tree: a path equal to it, every path
	 * ending in `extension` below it as a directory, or every path a glob matches. `listed` holds slash-separated paths
	 * as a revision lists them (`GitRevision`); a leading `./` of `spec`, and `.` alone, name them from the top.
	 */
	public static function expandListed(spec: String, extension: String, listed: Array<String>): Array<String> {
		final norm: String = listedForm(spec);
		final out: Array<String> = if (isGlob(norm)) {
			final re: EReg = globToRegex(norm, '/');
			listed.filter(p -> re.match(p));
		} else {
			listed.filter(p -> p == norm || ((norm == '' || p.startsWith('$norm/')) && p.endsWith(extension)));
		};
		out.sort((a: String, b: String) -> if (a < b)
			-1
		else if (a > b)
			1
		else
			0);
		return out;
	}

	/** Where a walk for `spec` starts: the literal part of a glob before its first wildcard, else `spec`; `.` for the top. */
	public static function walkRoot(spec: String): String {
		final norm: String = listedForm(spec);
		final root: String = isGlob(norm) ? globBase(norm) : norm;
		return root == '' ? '.' : root;
	}

	private static inline function isGlobChar(c: String): Bool {
		return c == '*' || c == '?' || c == '[';
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

	/**
	 * Translate a glob pattern to a fully-anchored regex over a string whose segments `separator` (one character)
	 * divides: the printable path string, or a qualified name.
	 */
	private static function globToRegex(spec: String, separator: String): EReg {
		final sep: String = '\\$separator';
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
						if (i + 2 < n && spec.charAt(i + 2) == separator) {
							buf.add('(?:.*$sep)?');
							i += 3; // noqa: magic-number
						} else {
							buf.add('.*');
							i += 2;
						}
					} else {
						buf.add('[^$sep]*');
						i++;
					}
				case '?':
					buf.add('[^$sep]');
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
						buf.add(body.startsWith('!') ? '^${body.substr(1)}' : body);
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

	/** `spec` as a listed path reads: no trailing `/`, no leading `./`, and empty for `.`. */
	private static function listedForm(spec: String): String {
		var norm: String = stripTrailingSlash(spec);
		while (norm.startsWith('./')) norm = norm.substr(2);
		return norm == '.' ? '' : norm;
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
	#end

}

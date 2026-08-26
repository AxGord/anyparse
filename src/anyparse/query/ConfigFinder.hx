package anyparse.query;

/**
 * Walks up the directory tree from a file looking for a named project config,
 * returning its content. The shared IO half of every walk-up config lookup
 * (`checkstyle.json` via `CheckstyleConfigFinder`, `apqlint.json` via
 * `LintConfig.discover`); the conditional compilation for file IO lives here in
 * one place so callers stay target-agnostic.
 */
@:nullSafety(Strict)
final class ConfigFinder {

	/**
	 * The files that mark a project root — the directory holding one is the LAST an
	 * inheriting walk reads, its own document included. Lives here rather than at the
	 * calling layer because it is a fact about the WALK, and any future chain-folding
	 * config must stop at the same place this one does.
	 */
	public static final PROJECT_ROOT_MARKERS: Array<String> = ['.git', 'haxelib.json'];

	/**
	 * EVERY `filename` on the way up from `path`'s directory, NEAREST FIRST — the chain
	 * a config that EXTENDS its ancestors is folded from (`LintConfig.discover`), as
	 * opposed to the two nearest-only entries below, which are what a config that
	 * REPLACES its ancestors wants.
	 *
	 * `boundary` names the files that mark a project root (`.git`, `haxelib.json`): the
	 * directory holding one is the LAST the walk reads, its own document included. That
	 * bound is not tidiness. A nearest-only lookup treats a stray document in `/tmp` or
	 * `$HOME` as a fallback nobody reaches once the project ships its own; a CHAIN folds
	 * it in regardless, and `apqlint.json` carries `compilerOracle`, an hxml
	 * `CompilerOracle.typecheck` executes — an hxml is not inert (`--macro`, `--cmd`).
	 * Unbounded inheritance would let any writable ancestor directory choose what a lint
	 * of an unrelated project runs. Pass no boundary to walk to the filesystem root.
	 *
	 * An unreadable document does not stop the walk — the nearest config failing to open
	 * must not hide the ones above it — but its path is REPORTED in `unreadable` rather
	 * than dropped: silently losing a document the project wrote is the one outcome with
	 * no diagnostic at all. (`findUpFile` keeps its own contract: an unreadable nearest
	 * match is a null answer there, exactly as before.)
	 */
	public static inline function findUpAll(path: String, filename: String, ?boundary: Array<String>): ConfigChain {
		return walkUp(path, filename, false, boundary);
	}

	/**
	 * Walk up from `path`'s directory looking for a file named `filename` and
	 * return its content, or null when none is found, it cannot be read, or the
	 * target has no file IO.
	 */
	public static function findUp(path: String, filename: String): Null<String> {
		final found: Null<ConfigFile> = findUpFile(path, filename);
		return found?.content;
	}

	/**
	 * As `findUp`, but also returns the ABSOLUTE path of the config that matched, so a
	 * caller can resolve a config-relative setting against the config's own directory.
	 * Null when none is found, unreadable, or the target has no file IO. UNBOUNDED, as
	 * it always was — a nearest-only lookup is reached by a stray ancestor document only
	 * when the project ships none of its own, which is the fallback it is meant to be.
	 */
	public static function findUpFile(path: String, filename: String): Null<ConfigFile> {
		final found: Array<ConfigFile> = walkUp(path, filename, true).documents;
		return found.length == 0 ? null : found[0];
	}

	/**
	 * The shared walk: from `path`'s directory upward, collecting each readable
	 * `filename` and the path of each one that exists but cannot be read.
	 * `stopAtFirst` answers the nearest one only — and, faithful to the contract
	 * `findUpFile` has always had, treats an unreadable nearest match as no match at
	 * all rather than walking past it. `boundary` ends the walk AFTER the directory
	 * holding one of its files, so a project root's own document is still read.
	 */
	private static function walkUp(path: String, filename: String, stopAtFirst: Bool, ?boundary: Array<String>): ConfigChain {
		final out: Array<ConfigFile> = [];
		final unreadable: Array<String> = [];
		#if (sys || nodejs)
		var dir: String = haxe.io.Path.directory(sys.FileSystem.absolutePath(path));
		while (dir != '') {
			final candidate: String = '$dir/$filename';
			if (sys.FileSystem.exists(candidate) && !sys.FileSystem.isDirectory(candidate)) {
				final content: Null<String> = try sys.io.File.getContent(candidate) catch (exception: haxe.Exception) null;
				// Re-bound: strict null-safety does not carry a narrowed local into a structure literal.
				if (content == null)
					unreadable.push(candidate)
				else {
					final text: String = content;
					out.push({ content: text, path: candidate });
				}
				if (stopAtFirst) return { documents: out, unreadable: unreadable };
			}
			if (marksProjectRoot(dir, boundary)) break;
			final parent: String = haxe.io.Path.directory(dir);
			if (parent == dir) break;
			dir = parent;
		}
		#end
		return { documents: out, unreadable: unreadable };
	}

	/** Whether `dir` holds any of `boundary`'s files — the project root the walk stops at. False when no boundary was asked for. */
	private static function marksProjectRoot(dir: String, boundary: Null<Array<String>>): Bool {
		if (boundary == null) return false;
		#if (sys || nodejs)
		for (marker in boundary) if (sys.FileSystem.exists('$dir/$marker')) return true;
		#end
		return false;
	}

}

/**
 * One config document a walk-up found: its content and the ABSOLUTE path it was read
 * from, which is what lets a caller resolve a config-relative setting against the
 * directory of the document that declared it.
 */
typedef ConfigFile = {
	var content: String;
	var path: String;
}

/**
 * A whole walk-up: the readable documents nearest first, plus the paths of any that
 * EXIST and could not be read. The second list is not diagnostics tidiness — a chain
 * that silently drops a document the project wrote applies the ancestor's answer to a
 * question the project already answered, with nothing on stderr to say so.
 */
typedef ConfigChain = {
	var documents: Array<ConfigFile>;
	var unreadable: Array<String>;
}

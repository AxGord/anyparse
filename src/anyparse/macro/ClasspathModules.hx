package anyparse.macro;

using StringTools;

import anyparse.util.Compare;
import haxe.io.Path;
import sys.FileSystem;

/**
 * The one answer to "which modules do the classpath roots hold under a package": the compile-time walk a discovery
 * macro registers its modules from, so each discovery names only the files it wants. A dot-entry is never walked: a
 * module path through `.git` or a hidden tree is one the compiler cannot type.
 */
@:nullSafety(Strict)
final class ClasspathModules {

	/** The compiler's module file extension. */
	private static final MODULE_EXTENSION: String = '.hx';

	/**
	 * The module path of every module file under the package `pack` of the directories `roots` whose file name `accept`
	 * takes, deduped and sorted; an empty root and a root without the package are skipped.
	 */
	public static function under(roots: Array<String>, pack: Array<String>, accept: (String) -> Bool): Array<String> {
		final seen: Map<String, Bool> = [];
		for (root in roots) if (root != '') {
			final dir: String = Path.join([root].concat(pack));
			if (FileSystem.exists(dir) && FileSystem.isDirectory(dir)) collect(dir, pack, accept, seen);
		}
		final found: Array<String> = [ for (module in seen.keys()) module ];
		found.sort(Compare.compareString);
		return found;
	}

	/** Record in `seen` the module of every file under `dir` that `accept` takes, whose package is `pack`. */
	private static function collect(dir: String, pack: Array<String>, accept: (String) -> Bool, seen: Map<String, Bool>): Void {
		for (entry in FileSystem.readDirectory(dir)) if (!entry.startsWith('.')) {
			final full: String = Path.join([dir, entry]);
			if (FileSystem.isDirectory(full))
				collect(full, pack.concat([entry]), accept, seen)
			else if (entry.endsWith(MODULE_EXTENSION) && accept(entry))
				seen[pack.concat([entry.substr(0, entry.length - MODULE_EXTENSION.length)]).join('.')] = true;
		}
	}

}

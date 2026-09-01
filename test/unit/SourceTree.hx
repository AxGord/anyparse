package unit;

#if (sys || nodejs)
import sys.FileSystem;
#end

using StringTools;

/**
 * The `.hx` files under a directory tree, for the two tests that sweep one.
 *
 * `ApqAstIntegrationTest` walks `src/anyparse` and `DeadTestGuardTest` walks `test/`; both used
 * to carry their own copy of the recursion AND of the string comparator that orders it, and the
 * copies had already drifted apart in how they tested the extension. Sorting here rather than at
 * the call sites is what makes "in sorted order" true of every consumer — both of them depend on
 * a stable order, one for a deterministic sample and one for a stable failure message.
 *
 * Holds no test method, so it is never registered in `RunTests`.
 */
@:nullSafety(Strict)
final class SourceTree {

	#if (sys || nodejs)
	/** Every `.hx` under `dir`, recursively, in ascending path order. */
	public static function collect(dir: String): Array<String> {
		final paths: Array<String> = [];
		walk(dir, paths);
		paths.sort((a: String, b: String) -> if (a < b)
			-1
		else if (a > b)
			1
		else
			0);
		return paths;
	}

	/** Append every `.hx` under `dir`, recursively, to `into`. */
	private static function walk(dir: String, into: Array<String>): Void {
		for (name in FileSystem.readDirectory(dir)) {
			final path: String = '$dir/$name';
			if (FileSystem.isDirectory(path))
				walk(path, into);
			else if (name.endsWith('.hx'))
				into.push(path);
		}
	}
	#end

}

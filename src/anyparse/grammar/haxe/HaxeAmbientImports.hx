package anyparse.grammar.haxe;

import anyparse.query.ConfigFinder;
import anyparse.query.GrammarPlugin.AmbientImportSource;
import anyparse.query.GrammarPlugin.AmbientImports;
import haxe.io.Path;

/**
 * Haxe's ambient-import rule: a directory's `import.hx` binds names in every module stored in
 * that directory and below it, up to the source root, and a nearer one outranks a farther one.
 *
 * The file name and the walk live here rather than in the engine because ambient imports are
 * not a Haxe special case — a C# `global using` file and a Scala prelude are the same shape with
 * a different spelling — and the engine that unions them into a module's scope must not know
 * either.
 */
@:nullSafety(Strict)
final class HaxeAmbientImports {

	/** The file name Haxe reads a directory's ambient imports from. */
	private static inline final AMBIENT_FILE: String = 'import.hx';

	/**
	 * The `import.hx` chain in scope for the module at `path` with package `pkg`, nearest first.
	 *
	 * The chain stops at the SOURCE ROOT, which the compiler bounds at the classpath entry: an
	 * `import.hx` one directory above a `-cp` root is inert. Haxe requires a module's directory
	 * path below that root to mirror its package, so the root is `path`'s directory with one
	 * segment removed per package segment — no second notion of root, and nothing about the
	 * invoking command line to know.
	 *
	 * `bounded` is false when that stripping does not land on a root because some directory name
	 * does not match its package segment. The walk then reads only the module's own directory:
	 * the shortest chain, and the answer a consumer must refuse to pin against.
	 */
	public static function chainFor(path: String, pkg: String): AmbientImports {
		final root: Null<String> = sourceRootOf(path, pkg);
		final stop: String = named(root ?? Path.directory(path));
		final chain: Array<AmbientImportSource> = [
			for (doc in ConfigFinder.findUpTo(path, AMBIENT_FILE, stop).documents) { file: doc.path, source: doc.content }
		];
		return { sources: chain, bounded: root != null };
	}

	/**
	 * `dir` as a directory an absolute-path resolution can name. A relative module path whose
	 * package consumes every segment leaves the EMPTY string, which names the process directory to a
	 * reader and nothing at all to a path resolver — and a stop point that resolves to nothing bounds
	 * no walk, which is the one direction this must not fail in.
	 */
	private static inline function named(dir: String): String {
		return dir == '' ? '.' : dir;
	}

	/**
	 * `path`'s source root — its directory with one segment removed per segment of `pkg` — or null
	 * when a directory on the way up does not carry the name its package segment claims, which is
	 * the layout the compiler rejects and this walk cannot bound.
	 */
	private static function sourceRootOf(path: String, pkg: String): Null<String> {
		var dir: String = Path.removeTrailingSlashes(Path.directory(path));
		if (pkg == '') return dir;
		final segments: Array<String> = pkg.split('.');
		var i: Int = segments.length - 1;
		while (i >= 0) {
			if (Path.withoutDirectory(dir) != segments[i]) return null;
			final up: String = Path.removeTrailingSlashes(Path.directory(dir));
			if (up == dir) return null;
			dir = up;
			i--;
		}
		return dir;
	}

}

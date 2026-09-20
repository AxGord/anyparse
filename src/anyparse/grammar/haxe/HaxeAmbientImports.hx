package anyparse.grammar.haxe;

import anyparse.query.ConfigFinder;
import anyparse.query.GrammarPlugin.AmbientImportGovernance;
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

	/** The extension of a Haxe module file — what an `import.hx` governs and what it is not. */
	private static inline final MODULE_EXTENSION: String = 'hx';

	/**
	 * The `import.hx` chain in scope for the module at `path` with package `pkg`, nearest first.
	 *
	 * The chain stops at the SOURCE ROOT, which the compiler bounds at the classpath entry: an
	 * `import.hx` one directory above a `-cp` root is inert. Haxe requires a module's directory
	 * path below that root to mirror its package, so the root is `path`'s directory with one
	 * segment removed per package segment — no second notion of root, and nothing about the
	 * invoking command line to know.
	 *
	 * `bounded` is false whenever the chain is knowingly SHORT: the stripping did not land on a root
	 * because a directory name does not match its package segment, or a source that exists could not be
	 * read. A module absent from disk has no chain at all and is bounded — there is nothing short about
	 * it. A short chain binds names this answer does not carry, so a consumer that pins a reference to
	 * one declaration must refuse on a false rather than resolve against it.
	 */
	public static function chainFor(path: String, pkg: String): AmbientImports {
		// A module that is not ON DISK has no directory to walk and no ambient source that could reach
		// it — an analysed source with an invented path would otherwise take its chain from the process
		// directory, which is a different tree. Bounded, because there is no chain to be short about.
		if (!ConfigFinder.fileExists(path)) return { sources: [], bounded: true };
		final root: Null<String> = sourceRootOf(path, pkg);
		final stop: String = named(root ?? Path.directory(path));
		final walk: ConfigChain = ConfigFinder.findUpTo(path, AMBIENT_FILE, stop);
		final chain: Array<AmbientImportSource> = [
			for (doc in walk.documents) { file: doc.path, source: doc.content }
		];
		// A source that EXISTS and could not be read leaves the chain knowingly short, and a short chain
		// binds names this answer does not carry — the one state a consumer must refuse to pin against.
		return { sources: chain, bounded: root != null && walk.unreadable.length == 0 };
	}

	/**
	 * The modules `path` governs when `path` IS a directory's ambient source: every module stored in
	 * that directory and below it. The subtree is not cut at a nested ambient source, because a
	 * nested one EXTENDS its parents rather than replacing them — and an ambient source is not itself
	 * a module, so the walk skips them.
	 *
	 * `bounded` is false when a directory on the way down could not be listed or a module could not
	 * be read: the governed set is then short, and short is unusable rather than smaller — see
	 * `GrammarPlugin.ambientImportGovernance`.
	 */
	public static function governanceFor(path: String): Null<AmbientImportGovernance> {
		if (Path.withoutDirectory(path) != AMBIENT_FILE) return null;
		final governed: Array<AmbientImportSource> = [];
		final complete: Bool = collectModules(named(Path.directory(path)), governed);
		return { governs: governed, bounded: complete };
	}

	/**
	 * Every position an `import.hx` could occupy for the module at `path`, NEAREST FIRST: its own
	 * directory, then each directory up to and including the source root. Empty when the root
	 * cannot be computed, since a ladder with no top would propose a file the compiler ignores.
	 */
	public static function sitesFor(path: String, pkg: String): Array<String> {
		final root: Null<String> = sourceRootOf(path, pkg);
		if (root == null) return [];
		final stop: String = named(root);
		final out: Array<String> = [];
		var dir: String = named(Path.removeTrailingSlashes(Path.directory(path)));
		while (true) {
			out.push('$dir/$AMBIENT_FILE');
			if (dir == stop) break;
			final up: String = named(Path.removeTrailingSlashes(Path.directory(dir)));
			if (up == dir) break;
			dir = up;
		}
		return out;
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

	/** Every module stored under `dir` with its text, ambient sources excluded; false when one could not be read. */
	private static function collectModules(dir: String, out: Array<AmbientImportSource>): Bool {
		#if (sys || nodejs)
		final entries: Null<Array<String>> = try sys.FileSystem.readDirectory(dir) catch (_: haxe.Exception) null;
		if (entries == null) return false;
		var complete: Bool = true;
		for (name in entries) {
			final child: String = '$dir/$name';
			// EVERY io call here answers `null` rather than throwing: the governed subtree reaches past the
			// scope a run was given, so a dangling symlink whose stat throws would take the whole lint down.
			final isDir: Null<Bool> = try sys.FileSystem.isDirectory(child) catch (_: haxe.Exception) null;
			if (isDir == null) {
				complete = false;
				continue;
			}
			if (isDir) {
				if (!collectModules(child, out)) complete = false;
				continue;
			}
			if (name == AMBIENT_FILE || Path.extension(name) != MODULE_EXTENSION) continue;
			final text: Null<String> = try sys.io.File.getContent(child) catch (_: haxe.Exception) null;
			if (text == null)
				complete = false
			else {
				// Re-bound: strict null-safety does not carry a narrowed local into a structure literal.
				final read: String = text;
				out.push({ file: child, source: read });
			}
		}
		return complete;
		#else
		return false;
		#end
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

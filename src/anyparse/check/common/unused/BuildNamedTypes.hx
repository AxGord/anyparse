package anyparse.check.common.unused;

import anyparse.check.common.design.threads.LibraryBuild;
import anyparse.check.scan.PublicReach;
import anyparse.ds.Set;
import anyparse.query.ConfigFinder;
import haxe.Exception;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * The one answer to "which types does the project's build name with no written reference in any source": the `-main`
 * module and the identifiers of every `--macro` argument (`Init.run()` names `Init`; `include('pkg')` names a package and
 * so every type under it) of EVERY `.hxml` under the project root. An hxml has no grammar here, so its words are split the
 * way `LibraryBuild.tokens` splits them, and a macro argument is read for identifier tokens only, never parsed. The read
 * is RUN-scoped: nothing is kept between runs.
 */
@:nullSafety(Strict)
final class BuildNamedTypes {

	/** Directories whose `.hxml` files belong to no build of the project. */
	private static final SKIPPED_DIRECTORIES: Array<String> = ['node_modules'];

	private final _entries: Set<String> = new Set<String>();
	private final _macroTokens: Map<String, Int> = [];

	private function new() {}

	/** Whether the build names the type `name` of package `pkg`: as the entry, in a macro argument, or through its package. */
	public function names(name: String, pkg: String): Bool {
		return _entries.has(name)
			|| _macroTokens.exists(name)
			|| (pkg != '' && pkg.split('.').foreach(segment -> _macroTokens.exists(segment)));
	}

	private function add(tokens: HxmlTokens): Void {
		for (entry in tokens.mains) _entries.add(entry.split('.').pop() ?? entry);
		for (argument in tokens.macros) PublicReach.countTokens(argument, 0, argument.length, _macroTokens);
	}

	/** Every build argument naming a type, read from the hxml files under the root of the project `files[0]` belongs to. */
	public static function read(files: Array<{ file: String, source: String }>): BuildNamedTypes {
		final out: BuildNamedTypes = new BuildNamedTypes();
		if (files.length == 0) return out;
		for (path in hxmlFiles(rootOf(ConfigFinder.absolute(files[0].file)))) {
			final text: Null<String> = try File.getContent(path) catch (exception: Exception) null;
			if (text != null) out.add(LibraryBuild.tokens(text));
		}
		return out;
	}

	private static function hxmlFiles(dir: String): Array<String> {
		final out: Array<String> = [];
		final entries: Array<String> = try FileSystem.readDirectory(dir) catch (exception: Exception) [];
		for (entry in entries) {
			final path: String = Path.join([dir, entry]);
			if (entry.startsWith('.') || SKIPPED_DIRECTORIES.contains(entry)) continue;
			if (FileSystem.isDirectory(path))
				for (nested in hxmlFiles(path)) out.push(nested);
			else if (path.endsWith('.hxml'))
				out.push(path);
		}
		return out;
	}

	/**
	 * The project root a linted file belongs to: the directory of the outermost `apq.json` on the way up, else the directory
	 * holding a root marker, else the directory the lint runs in — a project with neither has its hxml somewhere the files give
	 * no hint of, and only then is the working directory walked.
	 */
	private static function rootOf(file: String): String {
		final start: String = Path.directory(file);
		final documents: Array<ConfigFile> = try
			ConfigFinder.findUpProject(file, ConfigFinder.PROJECT_ROOT_MARKERS).documents
		catch (exception: Exception)
			[];
		final outermost: Null<ConfigFile> = documents[documents.length - 1];
		return outermost != null
			? Path.directory(outermost.path)
			: ConfigFinder.projectRoot(start) ?? Path.removeTrailingSlashes(Sys.getCwd());
	}

}

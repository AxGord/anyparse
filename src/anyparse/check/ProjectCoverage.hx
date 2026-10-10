package anyparse.check;

import haxe.Exception;
import haxe.io.Path;

using StringTools;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end

/**
 * Whether a lint run holds every source of the project a `closedWorld` declaration closes — the half of "every caller
 * and every write is in the run" a declaration cannot promise, since the same `apqlint.json` governs `hxq lint src` and
 * `hxq lint src/core` alike.
 *
 * The project is the declaring document's: the `.hx` files under its `resolutionRoots` when it declares any (relative
 * entries resolved against its directory; a root that does not exist holds nothing), else under its own directory —
 * the OUTERMOST document of the file's chain that declares `closedWorld` for `thread-safety` or
 * `resolutionRoots`, so a nested config restating `closedWorld` closes no project of its own and a
 * run over its directory alone covers nothing. A path `exclude` names is no part of it. Positive: a
 * file of the project the run does not hold, a document that cannot be read, or a target without a file system, and
 * the run does not cover it.
 */
@:nullSafety(Strict)
final class ProjectCoverage {

	/** The run's files, each by its canonical path (`OracleCoverage.canonical`). */
	private final _run: Map<String, Bool> = [];

	/** Each directory of a run file -> the document declaring `closedWorld` for it, `''` for none. */
	private final _documentOf: Map<String, String> = [];

	/** `<document>\t<exclude>` -> whether the run covers that document's project. */
	private final _covered: Map<String, Bool> = [];

	public function new(files: Array<String>) {
		#if (sys || nodejs)
		final cwd: String = Sys.getCwd();
		for (f in files) _run[OracleCoverage.canonical(cwd, f)] = true;
		#end
	}

	/** Whether the run covers the project of the `closedWorld` declaration governing `file`, the paths `exclude` names left out. */
	public function covers(file: String, exclude: Array<String>): Bool {
		#if (sys || nodejs)
		final document: String = projectOf(file);
		if (document == '') return false;
		final key: String = '$document\t' + exclude.join('\n');
		final known: Null<Bool> = _covered[key];
		if (known != null) return known;
		final answer: Bool = holdsProject(document, path -> excluded(path, exclude));
		_covered[key] = answer;
		return answer;
		#else
		return false;
		#end
	}

	/** The document whose project `file`'s `closedWorld` closes (`declaringDocument`); `''` for none, or a target without a file system. */
	public function projectOf(file: String): String {
		#if (sys || nodejs)
		final dir: String = Path.directory(file);
		final document: String = _documentOf[dir] ?? declaringDocument(file);
		_documentOf[dir] = document;
		return document;
		#else
		return '';
		#end
	}

	/**
	 * Whether `exclude` names `file`: an entry, its leading and trailing `/` trimmed, occurs in the path as a run of
	 * whole `/`-bounded segments (`src/tests` drops `src/tests/A.hx`, never `src/testsuite/A.hx`).
	 */
	public static function excluded(file: String, exclude: Array<String>): Bool {
		final wrapped: String = '/' + file.replace('\\', '/') + '/';
		for (p in exclude) {
			var trimmed: String = p;
			while (trimmed.startsWith('/')) trimmed = trimmed.substring(1);
			while (trimmed.endsWith('/')) trimmed = trimmed.substring(0, trimmed.length - 1);
			if (trimmed.length > 0 && wrapped.indexOf('/$trimmed/') != -1) return true;
		}
		return false;
	}

	#if (sys || nodejs)
	/**
	 * Whether every `.hx` file of the project `document` declares is a run file, those `skip` answers for left out — asked
	 * of each path relative to the document's directory, as `exclude` is written. A directory reached twice (a symlink
	 * cycle) is walked once; one that cannot be listed leaves the project uncovered.
	 */
	private function holdsProject(document: String, skip: (String) -> Bool): Bool {
		final content: Null<String> = try File.getContent(document) catch (_: Exception) null;
		if (content == null) return false;
		final base: String = Path.addTrailingSlash(Path.directory(document));
		final roots: Array<String> = LintConfig.parse(content, base).resolutionRoots();
		final cwd: String = Sys.getCwd();
		final stack: Array<String> = roots.length > 0 ? [for (r in roots) Path.isAbsolute(r) ? r : Path.join([base, r])] : [base];
		final walked: Map<String, Bool> = [];
		while (stack.length > 0) {
			final path: String = stack.pop() ?? '';
			if (skip(path.startsWith(base) ? path.substring(base.length) : path) || !FileSystem.exists(path)) continue;
			final canonical: String = OracleCoverage.canonical(cwd, path);
			if (!FileSystem.isDirectory(path)) {
				if (path.endsWith('.hx') && !_run.exists(canonical)) return false;
				continue;
			}
			if (walked.exists(canonical)) continue;
			walked[canonical] = true;
			final names: Null<Array<String>> = try FileSystem.readDirectory(path) catch (_: Exception) null;
			if (names == null) return false;
			for (name in names) stack.push(Path.join([path, name]));
		}
		return true;
	}

	/**
	 * The OUTERMOST document of `file`'s chain that declares `closedWorld` for `thread-safety`, or `resolutionRoots`; `''`
	 * when none does, or one cannot be read. A nested document restating `closedWorld` closes no project of its own: the
	 * run must still cover the outer one, whose files may call and write into the inner directory.
	 */
	private static function declaringDocument(file: String): String {
		var found: String = '';
		for (path in LintConfig.discoverChain(file).chain) {
			final content: Null<String> = try File.getContent(path) catch (_: Exception) null;
			if (content == null) return '';
			final config: LintConfig = LintConfig.parse(content, Path.directory(path));
			if (config.boolOption('thread-safety', 'closedWorld') != null || config.resolutionRoots().length > 0) found = path;
		}
		return found;
	}
	#end

}

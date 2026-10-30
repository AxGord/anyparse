package anyparse.query.cli;

import anyparse.check.oracle.HaxeSpawn;
import anyparse.query.Glob;
import haxe.io.Path;
import sys.FileSystem;

using Lambda;

/**
 * What a git revision holds, read through `git` with no shell in between: a file's text at a revision, the files a
 * revision holds under a scope, and the paths two revisions differ in. Paths are relative to
 * the process cwd, as git reads a pathspec there; an absolute input is read relative to it.
 */
@:nullSafety(Strict)
final class GitRevision {

	/** The output cap of one `git` child: a `git show` of a large file must not truncate. */
	private static inline final GIT_BUFFER: Int = 256 * 1024 * 1024;

	/** `git diff --name-status -z` records: a status field, then one path, or two for a rename or a copy. */
	public static function parseNameStatus(out: String): Array<ChangedPath> {
		final fields: Array<String> = out.split('\x00');
		final entries: Array<ChangedPath> = [];
		var i: Int = 0;
		while (i < fields.length) {
			final status: String = fields[i];
			if (status.length == 0) {
				i++;
				continue;
			}
			final letter: String = status.charAt(0);
			final pathCount: Int = letter == 'R' || letter == 'C' ? 2 : 1;
			if (i + pathCount >= fields.length) break;
			entries.push({ status: letter, basePath: fields[i + 1], path: fields[i + pathCount] });
			i += 1 + pathCount;
		}
		return entries;
	}

	/**
	 * The files revision `ref` holds that the inputs `specs` name, read as `Glob.expand` reads them over the working tree
	 * (`Glob.expandListed`), each once, in the order the specs name them; null when git lists no tree for `ref`.
	 */
	public static function filesAt(ref: String, specs: Array<String>, extension: String): Null<Array<RevisionFile>> {
		// a revision spelled as an option would reach git as one
		if (ref.startsWith('-')) return null;
		final relative: Array<String> = specs.map(cwdRelative);
		final listed: HaxeRun = git(['ls-tree', '-r', '-z', ref, '--'].concat(rootsOf(relative)));
		if (listed.failure != '' || listed.status != 0) return null;
		final blobs: Map<String, String> = [];
		final paths: Array<String> = [];
		for (record in listed.out.split('\x00')) {
			// `<mode> <type> <object>` and a tab before the path
			final tab: Int = record.indexOf('\t');
			if (tab < 0) continue;
			final head: Array<String> = record.substr(0, tab).split(' ');
			if (head.length < 3 || head[1] != 'blob') continue;
			final path: String = record.substr(tab + 1);
			blobs[path] = head[2];
			paths.push(path);
		}
		final out: Array<RevisionFile> = [];
		for (spec in relative)
			for (path in Glob.expandListed(spec, extension, paths))
				if (!out.exists(f -> f.path == path)) out.push({ path: path, blob: blobs[path] ?? '' });
		return out;
	}

	/**
	 * Each file under the inputs `specs` that git finds renamed from revision `from` to `to`: its later path to its
	 * earlier one, both relative to the cwd; null when git cannot compare the two.
	 */
	public static function renamedBetween(from: String, to: String, specs: Array<String>): Null<Map<String, String>> {
		if (from.startsWith('-') || to.startsWith('-')) return null;
		final listed: HaxeRun = diffNameStatus([from, to], rootsOf(specs.map(cwdRelative)));
		return listed.failure != '' || listed.status != 0 ? null : [
			for (entry in parseNameStatus(listed.out)) if (entry.status == 'R') entry.path => entry.basePath
		];
	}

	/**
	 * `git diff --name-status -z` with rename detection between `revisions` (one: against the working tree), limited to
	 * `paths`, each path printed relative to the cwd: the records `parseNameStatus` reads.
	 */
	public static function diffNameStatus(revisions: Array<String>, paths: Array<String>): HaxeRun {
		return git(['diff', '--name-status', '-z', '-M', '--relative'].concat(revisions).concat(['--']).concat(paths));
	}

	/** The text of the object `blob`, or null when git cannot read it. */
	public static function blobText(blob: String): Null<String> {
		final shown: HaxeRun = git(['cat-file', 'blob', blob]);
		return shown.failure == '' && shown.status == 0 ? shown.out : null;
	}

	/** `path` as revision `ref` holds it, or null when it holds none. */
	public static function sourceAt(ref: String, path: String): Null<String> {
		final shown: HaxeRun = git(['show', '$ref:./$path']);
		return shown.failure == '' && shown.status == 0 ? shown.out : null;
	}

	public static function git(args: Array<String>): HaxeRun {
		return HaxeSpawn.exec({ cmd: 'git', args: args, cwd: null }, GIT_BUFFER);
	}

	/** Where git starts listing for each of `specs`, each once (`Glob.walkRoot`). */
	private static function rootsOf(specs: Array<String>): Array<String> {
		final roots: Array<String> = [];
		for (spec in specs) {
			final root: String = Glob.walkRoot(spec);
			if (!roots.contains(root)) roots.push(root);
		}
		return roots;
	}

	/**
	 * `spec` relative to the cwd, `..` where it lies outside, as git lists paths; a relative one as written. An absolute
	 * path that exists is resolved through its links first, as the cwd is, so a linked prefix does not hide a common one.
	 */
	private static function cwdRelative(spec: String): String {
		if (!Path.isAbsolute(spec)) return spec;
		final here: Array<String> = segments(FileSystem.fullPath(Sys.getCwd()));
		final there: Array<String> = segments(FileSystem.exists(spec) ? FileSystem.fullPath(spec) : spec);
		var common: Int = 0;
		while (common < here.length && common < there.length && here[common] == there[common]) common++;
		final parts: Array<String> = [for (_ in common ... here.length) '..'].concat(there.slice(common));
		return parts.length == 0 ? '.' : parts.join('/');
	}

	private static function segments(path: String): Array<String> {
		return Path.normalize(path).split('/').filter(s -> s != '');
	}

}

/** One path `git diff --name-status` reports: its status letter, its path now, and its path at the base revision. */
typedef ChangedPath = {
	final status: String;
	final path: String;
	final basePath: String;
}

/** One file a revision holds: its path, relative to the cwd, and the id of its content, the same for the same text. */
typedef RevisionFile = {
	final path: String;
	final blob: String;
}

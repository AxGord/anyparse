package dev;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.query.ConfigFinder;
import devkit.Cmd.cmd;
import devkit.RawJson;
import devkit.Result;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * The one answer to "which files must a battery re-lint for a landing, and which findings of the base snapshot does that
 * leave standing": a landing that changes no engine input and no lint configuration re-lints the `.hx` files it changed,
 * every `.hx` beside them (a rule that counts a folder's files moves a finding filed on a sibling) and each `import.hx` up
 * the path to the root (ambient imports are inherited down it), and carries the base's findings for every other file.
 * Anything else — or no way to tell — is the whole tree (`null`). `backstop` is the whole lint's check of that carrying.
 */
final class LintScope {

	/** The directories the battery lints. */
	public static final ROOTS: Array<String> = ['src', 'test'];

	private static inline final AMBIENT: String = 'import.hx';

	/** How many moved findings a backstop refusal names. */
	private static inline final NAMED: Int = 3;

	/** The other files a lint reads besides the sources: the oracle's build files, the formatter's config, the library list. */
	private static final INPUT_FILES: Array<String> = ['hxformat.json', 'haxelib.json'];

	/**
	 * The files to re-lint for the paths `changed` — both sides of a rename and every deleted path included — or null for the
	 * whole tree. `filesIn` answers the repository-relative paths of the `.hx` files directly in a directory, `below` those in it
	 * and every directory under it (none for a directory that does not exist); a changed `import.hx` widens to `below` its
	 * folder, since its imports are inherited by every folder under it. Sorted, without repeats, and only inside `ROOTS`.
	 */
	public static function ofChange(
		changed: Array<String>, filesIn: String -> Array<String>, below: String -> Array<String>
	): Null<Array<String>> {
		if (changed.exists(isLintInput)) return null;
		final files: Map<String, Bool> = [];
		for (path in changed) if (path.endsWith('.hx') && inRoots(path)) {
			var dir: String = Path.directory(path);
			final here: Array<String> = Path.withoutDirectory(path) == AMBIENT ? below(dir) : filesIn(dir);
			for (file in here) files[file] = true;
			while (dir != '') {
				for (file in filesIn(dir)) if (Path.withoutDirectory(file) == AMBIENT) files[file] = true;
				dir = Path.directory(dir);
			}
		}
		final scope: Array<String> = [for (file in files.keys()) if (inRoots(file)) file];
		scope.sort(Reflect.compare);
		return scope;
	}

	/**
	 * `ofChange` for what `repo`'s working tree changed against `base`, or null — the whole tree — when git cannot say, there is
	 * no base, or the run is not `impact`: only an impact run is followed by the whole-suite run that checks the carrying.
	 */
	public static function ofImpact(repo: String, base: Null<String>, impact: Bool): Null<Array<String>> {
		if (!impact || base == null) return null;
		final diff: Result = cmd('git -C $repo diff --name-only --no-renames $base').run();
		return diff.ok ? ofChange(diff.lines(), dir -> hxFilesIn(repo, dir), dir -> hxFilesBelow(repo, dir)) : null;
	}

	/**
	 * The report of the whole tree, from the base's report `base` and the lint `fresh` of `scope` alone: the base's findings of
	 * every file outside `scope` that `exists` still, then the fresh ones. A `fresh` that is no report (a lint that failed) is answered
	 * as it is, for the caller to fail on; null when `base` is none.
	 */
	public static function carried(base: String, fresh: String, scope: Array<String>, exists: String -> Bool): Null<String> {
		final kept: Null<Array<JValue>> = recordsOf(base);
		final added: Null<Array<JValue>> = recordsOf(fresh);
		if (added == null) return fresh;
		if (kept == null) return null;
		final redone: Map<String, Bool> = [for (file in scope) file => true];
		final stay: Array<JValue> = kept.filter(record -> {
			final file: String = RawJson.stringAt(record, 'file') ?? '';
			return !redone.exists(file) && exists(file);
		});
		return RawJson.print(JArray(stay.concat(added)), '  ');
	}

	/**
	 * Why the whole lint `truth` of a landed commit is not the report `recorded` for it, or null when they hold the same
	 * findings: a finding moved in a file the landing's scoped lint did not re-lint. Names the first few, by file and rule.
	 */
	public static function backstop(recorded: String, truth: String): Null<String> {
		final lines: Array<String> = moved(recorded, truth);
		if (lines.length == 0) return null;
		final shown: String = lines.slice(0, NAMED).join('; ');
		return 'the whole lint moved ${lines.length} finding(s) the scoped lint did not re-lint — $shown';
	}

	/** The findings by which `now` differs from `old`, as `+ <file> <rule>` / `- <file> <rule>`, one per finding, sorted. */
	public static function moved(old: String, now: String): Array<String> {
		final balance: Map<String, Int> = [];
		final names: Map<String, String> = [];
		for (record in recordsOf(old) ?? []) tally(balance, names, record, -1);
		for (record in recordsOf(now) ?? []) tally(balance, names, record, 1);
		final lines: Array<String> = [];
		for (key => count in balance) {
			final sign: String = count > 0 ? '+' : '-';
			for (_ in 0...(count > 0 ? count : -count)) lines.push('$sign ${names[key]}');
		}
		lines.sort(Reflect.compare);
		return lines;
	}

	/**
	 * The arguments of the lint that makes the fresh half of a landing's report for `scope` (null: the whole tree), or null when
	 * `scope` is empty.
	 */
	public static function lintArgs(scope: Null<Array<String>>): Null<Array<String>> {
		final files: Array<String> = scope ?? ROOTS;
		return files.length == 0 ? null : ['lint', '--format', 'json', '--all'].concat(files);
	}

	/**
	 * The report a landing keeps: `fresh`, the lint of `lintArgs(scope)`, alone for the whole tree (`scope` null or no `base`
	 * snapshot file to carry), else `carried`. `exists` answers whether a repository-relative file is still there.
	 */
	public static function whole(base: Null<String>, scope: Null<Array<String>>, fresh: String, exists: String -> Bool): Null<String> {
		return scope == null || base == null ? fresh : carried(File.getContent(base), fresh, scope, exists);
	}

	private static function tally(balance: Map<String, Int>, names: Map<String, String>, record: JValue, step: Int): Void {
		final key: String = RawJson.print(record);
		balance[key] = (balance[key] ?? 0) + step;
		names[key] = '${RawJson.stringAt(record, 'file') ?? '?'} ${RawJson.stringAt(record, 'rule') ?? '?'}';
	}

	private static function recordsOf(report: String): Null<Array<JValue>> {
		return report.trim().startsWith('[')
			? switch JValueParser.parse(report) {
				case JArray(records): records;
				case _: null;
			}
			: null;
	}

	private static function inRoots(path: String): Bool {
		return ROOTS.exists(root -> path.startsWith('$root/'));
	}

	private static function hxFilesIn(repo: String, dir: String): Array<String> {
		final full: String = Path.join([repo, dir]);
		return !FileSystem.exists(full) || !FileSystem.isDirectory(full) ? [] : [
			for (name in FileSystem.readDirectory(full)) if (name.endsWith('.hx')) Path.join([dir, name])
		];
	}

	/**
	 * Whether a change to `path` can move a finding in any file: an engine input, a project lint config (current or legacy
	 * name, at any depth), a build file (the compiler oracle's), the formatter's config or the library list.
	 */
	private static function isLintInput(path: String): Bool {
		final name: String = Path.withoutDirectory(path);
		return GateTree.isEngineInput(path)
			|| name == ConfigFinder.PROJECT_CONFIG
			|| name == ConfigFinder.LEGACY_PROJECT_CONFIG
			|| path.endsWith('.hxml')
			|| INPUT_FILES.contains(name);
	}

	private static function hxFilesBelow(repo: String, dir: String): Array<String> {
		final files: Array<String> = hxFilesIn(repo, dir);
		final full: String = Path.join([repo, dir]);
		if (!FileSystem.exists(full) || !FileSystem.isDirectory(full)) return files;
		for (name in FileSystem.readDirectory(full)) {
			final sub: String = Path.join([dir, name]);
			if (FileSystem.isDirectory(Path.join([repo, sub]))) for (file in hxFilesBelow(repo, sub)) files.push(file);
		}
		return files;
	}

}

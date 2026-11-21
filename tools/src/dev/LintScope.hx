package dev;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueTools;
import anyparse.grammar.json.JValueWriter;
import anyparse.grammar.json.JsonFormat;
import anyparse.query.ConfigFinder;
import dev.GateLint.LintMove;
import devkit.Cmd.cmd;
import devkit.Result;
import devkit.TreeFiles;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/** The report `LintScope.whole` makes, or the reason it cannot. */
typedef WholeReport = { report: Null<String>, why: Null<String> }

/**
 * The one answer to "which files must a battery re-lint for a landing, and which findings of the base snapshot does that
 * leave standing": a landing that changes no engine input and no lint configuration re-lints the `.hx` files it changed,
 * every `.hx` beside them (a rule that counts a folder's files moves a finding filed on a sibling) and every module governed
 * by an `import.hx` up the path to the root (its imports are inherited by every folder under it, and a rule that counts a
 * share of them moves with any module there), and carries the base's findings for every other file, and
 * those of a rule whose answer depends on the report scope (`Check.ScopeDependent`) even for a re-linted file, except an
 * ambient-governed one (`Check.AmbientGoverned`) on a re-linted file whose folder the scope holds whole, which is judged fresh.
 * Anything else — or no way to tell — is the whole tree (`null`). `backstop` is the whole lint's check of that carrying.
 */
final class LintScope {

	/** The directories the battery lints. */
	public static final ROOTS: Array<String> = ['src', 'test'];

	/** The engine's rule listing, read by `carriedRules`. */
	public static final RULE_LISTING: Array<String> = ['lint', '--list-rules', '--format', 'json'];

	/** How many moved findings a backstop refusal names. */
	private static inline final NAMED: Int = 3;

	private static final FILE_KEY: String = 'file';
	private static final AMBIENT: String = 'import.hx';

	/** The other files a lint reads besides the sources: the oracle's build files, the formatter's config, the library list. */
	private static final INPUT_FILES: Array<String> = ['hxformat.json', 'haxelib.json'];

	/**
	 * The files to re-lint for the paths `changed` — both sides of a rename and every deleted path included — or null for the
	 * whole tree. `filesIn` answers the repository-relative paths of the `.hx` files directly in a directory, `below` those in it
	 * and every directory under it (none for a directory that does not exist); a changed `import.hx` widens to `below` its
	 * folder, since its imports are inherited by every folder under it, as does an `import.hx` above a changed file. Sorted, without
	 * repeats, and only inside `ROOTS`.
	 */
	public static function ofChange(
		changed: Array<String>, filesIn: String -> Array<String>, below: String -> Array<String>
	): Null<Array<String>> {
		return changed.exists(isLintInput) ? null : governed(changed, filesIn, below);
	}

	/**
	 * The files a change to `changed` moves the lint of, the whole-tree answer of `ofChange` left out: the `.hx` files beside each
	 * changed one and every module below each `import.hx` above it. For a caller that lints the changed files anyway and has no
	 * whole tree to fall back to, so a change to the engine still widens to the modules its folders' ambient imports govern.
	 */
	public static function governed(
		changed: Array<String>, filesIn: String -> Array<String>, below: String -> Array<String>
	): Array<String> {
		final files: Map<String, Bool> = [];
		for (path in changed) if (path.endsWith('.hx') && inRoots(path)) {
			var dir: String = Path.directory(path);
			final here: Array<String> = Path.withoutDirectory(path) == AMBIENT ? below(dir) : filesIn(dir);
			for (file in here) files[file] = true;
			while (dir != '') {
				final own: Array<String> = filesIn(dir);
				if (own.exists(file -> Path.withoutDirectory(file) == AMBIENT)) for (file in below(dir)) files[file] = true;
				dir = Path.directory(dir);
			}
		}
		final scope: Array<String> = [ for (file in files.keys()) if (inRoots(file)) file ];
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
		return diff.ok ? ofTree(repo, diff.lines()) : null;
	}

	/**
	 * The report of the whole tree, from the base's report `base` and the lint `fresh` of `scope` alone: the base's findings of
	 * every file outside `scope` that `exists` still and those of a rule in `dependent` (`carriedRules`: its answer for a re-linted
	 * file is the narrow run's, so the base's stands), then the fresh ones of every other rule. A rule in `ambient`
	 * (`ambientRules`) is judged fresh only on a file whose folder `scope` holds whole — every file `below` it, the seam `governed`
	 * reads — since the narrow run weighs no site it does not hold; on any other file the base's finding stands. A `fresh` that is
	 * no report (a lint that failed) is answered as it is, for the caller to fail on; null when `base` is none.
	 */
	public static function carried(
		base: String, fresh: String, scope: Array<String>, exists: String -> Bool, dependent: Array<String>, ambient: Array<String>,
		below: String -> Array<String>
	): Null<String> {
		final kept: Null<Array<JValue>> = recordsOf(base);
		final added: Null<Array<JValue>> = recordsOf(fresh);
		if (added == null) return fresh;
		if (kept == null) return null;
		final redone: Map<String, Bool> = [ for (file in scope) file => true ];
		final narrow: Map<String, Bool> = [ for (id in dependent) id => true ];
		final governs: Map<String, Bool> = [ for (id in ambient) id => true ];
		final whole: Map<String, Bool> = [];
		final held: String -> Bool = file -> {
			final dir: String = Path.directory(file);
			if (!whole.exists(dir)) whole[dir] = below(dir).foreach(redone.exists);
			return whole[dir] == true;
		};
		final isNarrow: JValue -> Bool = record -> {
			final rule: String = JValueTools.stringAt(record, 'rule') ?? '';
			return narrow.exists(rule) || (governs.exists(rule) && !held(JValueTools.stringAt(record, FILE_KEY) ?? ''));
		};
		final stay: Array<JValue> = kept.filter(record -> {
			final file: String = JValueTools.stringAt(record, FILE_KEY) ?? '';
			return exists(file) && (!redone.exists(file) || isNarrow(record));
		});
		return JValueWriter.write(JArray(stay.concat(added.filter(record -> !isNarrow(record)))), JsonFormat.instance.expandedWriteOptions);
	}

	/**
	 * Why the whole lint of a landed commit is not the report recorded for it — `moved`, their `lint-diff` — or null when they hold
	 * the same findings by that compare's identity, which leaves out positions and masks a message's measurements: a finding `carried`
	 * kept from the base has its base-time line and its base-time count. Names the first few, by file and rule.
	 */
	public static function backstop(moved: LintMove): Null<String> {
		if (moved.added + moved.removed == 0) return null;
		final shown: String = moved.rows.slice(0, NAMED).join('; ');
		return 'the whole lint moved ${moved.added + moved.removed} finding(s) the scoped lint did not re-lint — $shown';
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
	 * snapshot file to carry), else `carried` with the `carriedRules` and `ambientRules` of the engine's rule listing — `listing`,
	 * asked only then. `exists` answers whether a repository-relative file is still there, `below` the `.hx` files in a directory
	 * and every directory under it. A report that cannot be made answers why.
	 */
	public static function whole(
		base: Null<String>, scope: Null<Array<String>>, fresh: String, exists: String -> Bool, below: String -> Array<String>,
		listing: () -> String
	): WholeReport {
		if (scope == null || base == null) return { report: fresh, why: null };
		final listed: String = listing();
		final dependent: Null<Array<String>> = carriedRules(listed);
		if (dependent == null)
			return { report: null, why: 'the engine\'s rule listing printed no report, so the scoped lint cannot be carried' };
		final report: Null<String> = carried(File.getContent(base), fresh, scope, exists, dependent, ambientRules(listed) ?? [], below);
		return { report: report, why: report == null ? 'the base snapshot $base is no lint report to carry' : null };
	}

	/**
	 * The ids of the rules a landing carries from its base on every re-linted file — those the engine's rule listing `listing`
	 * names scope-dependent and not ambient-governed — or null when `listing` is no listing.
	 */
	public static function carriedRules(listing: String): Null<Array<String>> {
		return markedIn(
			listing,
			record ->
				JValueTools.isTrue(JValueTools.field(record, 'scopeDependent'))
				&& !JValueTools.isTrue(JValueTools.field(record, 'ambientGoverned'))
		);
	}

	/**
	 * The ids of the rules the engine's rule listing `listing` names ambient-governed (`Check.AmbientGoverned`), or null when
	 * `listing` is no listing: `carried` judges them fresh on a re-linted file whose folder the scope holds whole.
	 */
	public static function ambientRules(listing: String): Null<Array<String>> {
		return markedIn(listing, record -> JValueTools.isTrue(JValueTools.field(record, 'ambientGoverned')));
	}

	/**
	 * Report `text` without the findings the landing's scoped lint carried by design: those of a rule in `dependent` on a file of
	 * `scope`. The backstop compares what is left, since a scoped lint never judged those. A `text` that is no report is answered as it is.
	 */
	public static function judged(text: String, scope: Array<String>, dependent: Array<String>): String {
		final records: Null<Array<JValue>> = recordsOf(text);
		if (records == null) return text;
		final redone: Map<String, Bool> = [ for (file in scope) file => true ];
		final narrow: Map<String, Bool> = [ for (id in dependent) id => true ];
		return JValueWriter.write(
			JArray(records.filter(record -> !(
				redone.exists(JValueTools.stringAt(record, FILE_KEY) ?? '') && narrow.exists(JValueTools.stringAt(record, 'rule') ?? '')
			))),
			JsonFormat.instance.expandedWriteOptions
		);
	}

	/**
	 * The one answer to "which modules does a change to the paths `changed` move the lint of", over the files `repo` holds:
	 * `ofChange` with the real directory listings.
	 */
	public static function ofTree(repo: String, changed: Array<String>): Null<Array<String>> {
		return ofChange(changed, dir -> hxFilesIn(repo, dir), dir -> hxFilesBelow(repo, dir));
	}

	/** `governed` over the files `repo`'s working tree holds. */
	public static function governedTree(repo: String, changed: Array<String>): Array<String> {
		return governed(changed, dir -> hxFilesIn(repo, dir), dir -> hxFilesBelow(repo, dir));
	}

	/**
	 * The repository-relative `.hx` files in `dir` of `repo` and every directory under it: the `below` of `ofTree`.
	 */
	public static function hxFilesBelow(repo: String, dir: String): Array<String> {
		return TreeFiles.below(repo, dir, _ -> true).filter(file -> file.endsWith('.hx'));
	}

	private static function recordsOf(report: String): Null<Array<JValue>> {
		return report.trim().startsWith('[')
			? switch JValueParser.parse(report) {
				case JArray(records): records;
				case _: null;
			}
			: null;
	}

	private static function markedIn(listing: String, marked: JValue -> Bool): Null<Array<String>> {
		final records: Null<Array<JValue>> = recordsOf(listing);
		return records == null ? null : [ for (record in records) if (marked(record)) JValueTools.stringAt(record, 'id') ?? '' ];
	}

	private static function inRoots(path: String): Bool {
		return ROOTS.exists(root -> path.startsWith('$root/'));
	}

	private static function hxFilesIn(repo: String, dir: String): Array<String> {
		final full: String = Path.join([repo, dir]);
		return !FileSystem.exists(full) || !FileSystem.isDirectory(full)
			? []
			: [ for (name in FileSystem.readDirectory(full)) if (name.endsWith('.hx')) Path.join([dir, name]) ];
	}

	/**
	 * Whether a change to `path` can move a finding in any file: an engine input, a project lint config (current or legacy
	 * name, at any depth), a build file (the compiler oracle's), the formatter's config or the library list.
	 */
	private static function isLintInput(path: String): Bool {
		final name: String = Path.withoutDirectory(path);
		return GateTree.isEngineInput(path)
			|| name == ConfigFinder.PROJECT_CONFIG || name == ConfigFinder.LEGACY_PROJECT_CONFIG
			|| path.endsWith('.hxml')
			|| INPUT_FILES.contains(name);
	}

}

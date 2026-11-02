package dev;

import devkit.Cmd.cmd;
import devkit.Result;
import devkit.Summary;
import devkit.Summary.Outcome;
import haxe.Exception;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * The one answer to "which prose files still name a path the landed commit deleted or renamed": the `prose-refs` row of
 * `dev land`. A moved or removed file leaves its old name behind in the documents and prompts that describe it, and no
 * compiler or gate reports that. The row is report-only: it lists `file:line` hits and never fails the landing.
 */
@:nullSafety(Strict)
final class LandProse {

	/** How many hits the row names before it counts the rest; the log holds all of them. */
	private static inline final NAMED: Int = 6;

	/** The deepest directory the search descends, so a link back to a parent cannot loop it. */
	private static inline final DEPTH: Int = 12;

	/** The prose under `docs/` that is a record of the past, not a description of the tree: it is never searched. */
	private static final HISTORY: Array<String> = ['docs/decisions.md', 'docs/journal/', 'docs/archive/'];

	/** The prose files outside `docs/` the repository keeps, each a file or a directory searched whole. */
	private static final PROSE: Array<String> = ['CLAUDE.md', '.claude/workflows'];

	private final _repo: String;
	private final _skills: Null<String>;
	private final _log: String;
	private final _summary: Summary;

	/** The step over the commit at the head of `repo`; `skills` is the directory of skill documents, or null for none. */
	public function new(repo: String, skills: Null<String>, log: String, summary: Summary) {
		_repo = repo;
		_skills = skills;
		_log = log;
		_summary = summary;
	}

	/** The row: what the commit at the head deleted or renamed, and the prose that still names it. Never a failure. */
	public function run(): Outcome {
		try {
			return search();
		} catch (exception: Exception) {
			_summary.detail('not read: ${exception.message}');
			return Passed;
		}
	}

	private function search(): Outcome {
		final changes: Result = git(['diff', '--name-status', '-M', 'HEAD~1', 'HEAD']);
		final tree: Result = git(['ls-tree', '-r', '--name-only', 'HEAD']);
		if (!changes.ok || !tree.ok) return Skipped('the paths of the commit cannot be read');
		final surviving: Array<String> = tree.lines();
		final names: Array<String> = needles(vanished(changes.lines(), surviving), surviving);
		final hits: Array<String> = [];
		if (names.length > 0) for (file in proseFiles()) for (hit in scan(file.label, File.getContent(file.path), names)) hits.push(hit);
		if (hits.length == 0) {
			_summary.detail('none');
			return Passed;
		}
		File.saveContent(_log, hits.join('\n') + '\n');
		_summary.detail(reading(hits));
		return Passed;
	}

	/** The prose files of the tree: the repository's own, its `docs/` but for the records of the past, and the skills. */
	private function proseFiles(): Array<ProseFile> {
		final found: Array<ProseFile> = [];
		for (path in PROSE) collect(Path.join([_repo, path]), path, p -> true, found, 0);
		collect(Path.join([_repo, 'docs']), 'docs', p -> p.endsWith('.md') && !HISTORY.exists(h -> p == h || p.startsWith(h)), found, 0);
		final skills: Null<String> = _skills;
		if (skills != null) collect(skills, skills, p -> p.endsWith('.md'), found, 0);
		return found;
	}

	/** The files under `path` (known as `label`) that `accepted` takes by label, a missing path skipped. */
	private function collect(path: String, label: String, accepted: String -> Bool, into: Array<ProseFile>, depth: Int): Void {
		if (!FileSystem.exists(path) || depth > DEPTH) return;
		if (!FileSystem.isDirectory(path)) {
			if (accepted(label)) into.push({ path: path, label: label });
			return;
		}
		for (entry in FileSystem.readDirectory(path)) collect(Path.join([path, entry]), '$label/$entry', accepted, into, depth + 1);
	}

	private function git(words: Array<String>): Result {
		return cmd('git -C $_repo -c core.quotepath=off $words').run();
	}

	/** The reading of `hits`: the first few, and how many more the log holds. */
	public static function reading(hits: Array<String>): String {
		final rest: Int = hits.length - NAMED;
		return '${hits.length} hit(s): ${hits.slice(0, NAMED).join('; ')}${rest > 0 ? '; and $rest more' : ''}';
	}

	/**
	 * What the `git diff --name-status -M` rows `changes` take out of the tree: a deleted file and the old side of a rename,
	 * and every directory (the topmost of a nest) that holds no file of `surviving` any more.
	 */
	public static function vanished(changes: Array<String>, surviving: Array<String>): Vanished {
		final files: Array<String> = [];
		for (row in changes) {
			final columns: Array<String> = row.split('\t');
			final kind: String = columns[0].charAt(0);
			if (kind == 'D' && columns.length >= 2 || kind == 'R' && columns.length >= 3) files.push(columns[1]);
		}
		final emptied: Map<String, Bool> = [];
		for (file in files) {
			var dir: String = Path.directory(file);
			while (dir != '' && !emptied.exists(dir)) {
				emptied[dir] = !surviving.exists(path -> path.startsWith('$dir/'));
				dir = Path.directory(dir);
			}
		}
		final dirs: Array<String> = [
			for (dir => empty in emptied) if (empty && emptied[Path.directory(dir)] != true) dir
		];
		dirs.sort((a, b) -> if (a < b)
			-1
		else if (a > b)
			1
		else
			0);
		return { files: files, dirs: dirs };
	}

	/**
	 * The names to look for: every vanished path in full, and the basename of a vanished file as well when no surviving file
	 * shares it (a shared basename would name the survivor as often as the casualty).
	 */
	public static function needles(gone: Vanished, surviving: Array<String>): Array<String> {
		final kept: Map<String, Bool> = [for (path in surviving) Path.withoutDirectory(path) => true];
		final names: Array<String> = gone.files.concat(gone.dirs);
		for (file in gone.files) {
			final base: String = Path.withoutDirectory(file);
			if (!kept.exists(base) && !names.contains(base)) names.push(base);
		}
		return names;
	}

	/**
	 * The lines of `text` that name one of `names`, each as `<label>:<line> <names>`; a name counts where it is not part of a
	 * longer one, and a name inside a longer matched name is not listed beside it.
	 */
	public static function scan(label: String, text: String, names: Array<String>): Array<String> {
		final hits: Array<String> = [];
		final lines: Array<String> = text.split('\n');
		for (index in 0...lines.length) {
			final named: Array<String> = names.filter(name -> mentions(lines[index], name));
			final longest: Array<String> = named.filter(name -> !named.exists(other -> other.length > name.length && other.contains(name)));
			if (longest.length > 0) hits.push('$label:${index + 1} ${longest.join(', ')}');
		}
		return hits;
	}

	/**
	 * Whether `line` names `name` as a whole: a dot ending a sentence still does, a dot that goes on into a name does not.
	 */
	private static function mentions(line: String, name: String): Bool {
		var from: Int = 0;
		while (true) {
			final at: Int = line.indexOf(name, from);
			if (at < 0) return false;
			final end: Int = at + name.length;
			final extended: Bool = partOfName(line.charAt(end)) || line.charAt(end) == '.' && partOfName(line.charAt(end + 1));
			if (!partOfName(line.charAt(at - 1)) && !extended) return true;
			from = at + 1;
		}
	}

	/**
	 * Whether `char` can be part of a longer path or file name.
	 */
	private static function partOfName(char: String): Bool {
		return char != '' && ~/^[A-Za-z0-9_-]$/.match(char);
	}

}

/** The paths a commit takes out of the tree: files, and directories that hold none of the tree's files any more. */
typedef Vanished = {
	var files: Array<String>;
	var dirs: Array<String>;
}

/** A prose file: where it is read, and how a hit names it. */
private typedef ProseFile = {
	var path: String;
	var label: String;
}

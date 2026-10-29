package dev;

import devkit.Args;
import devkit.Cmd.cmd;
import haxe.io.Path;
import js.node.Buffer;
import js.node.Fs;
import js.node.fs.Stats;
import sys.FileSystem;

using Lambda;
using StringTools;

/**
 * `dev scrub-guard [--list PATH] [--private-root DIR]... [--range A..B | --pre-push] [--quiet]` — fails when text a downstream project
 * must not see published is about to enter the repository.
 *
 * The token list is NOT part of this repository, by design: a list of the names to keep out would itself publish them.
 * It is read from `--list` or from `ANYPARSE_SCRUB_LIST`, in git-filter-repo `--replace-text` form, so the file that
 * rewrites history is the same file that guards it — one entry per line, `old==>new`, `regex:<re>==>new` or
 * `literal:old==>new`; only the left-hand side is read. A `regex:` rule is a JavaScript regular expression.
 *
 * Without `--range` the tracked files of the work tree under the current directory are scanned (a file with a NUL byte
 * in its first `BINARY_PROBE` bytes is skipped, as filter-repo skips it). With `--range A..B` the lines that range ADDS
 * and its commit messages are scanned instead — what a push would publish (`tools/hooks/pre-push-scrub.sh`). A match
 * prints `<where>:<line>: rule <n>`, never the matched text.
 *
 * A `--private-root` (repeatable; or `ANYPARSE_SCRUB_PRIVATE_ROOTS`, `:`-separated) is a downstream checkout: a
 * path-shaped token (a `/` or `\` path, a dotted module path) that names one of its
 * files or directories and none of the scanned tree's is a match too, printed as
 * `<where>:<line>: private root <k>` — the structural half, for the path no list entry spells (`privatePaths`).
 *
 * Exit 0 = clean, or nothing configured (said on stderr, so a clone without the private list is not blocked); 1 = a
 * match; 2 = a usage error, or a scan that could not run.
 */
@:nullSafety(Strict)
final class ScrubGuard {

	public static inline final USAGE: String =
		'usage: dev scrub-guard [--list PATH] [--private-root DIR]... [--range A..B | --pre-push] [--quiet]';

	/** How many leading bytes of a file are looked at for a NUL before it counts as binary. */
	private static inline final BINARY_PROBE: Int = 8192;

	/** How many segments a path must have to name a directory: fewer are too common a phrase to be one project's. */
	private static inline final DIRECTORY_SEGMENTS: Int = 3;

	/** Directory names a project keeps its modules under, which say nothing about the project. */
	private static final SOURCE_ROOT_NAMES: Array<String> = ['src', 'source', 'lib', 'test', 'tests'];

	/**
	 * Run the subcommand over `argv`; answers the exit status. `--pre-push` reads git's pre-push
	 * lines on stdin and scans what each pushed ref publishes (`tools/hooks/pre-push-scrub.sh`).
	 */
	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final quiet: Bool = args.flag('--quiet');
		final list: Null<String> = args.option('--list') ?? Sys.getEnv('ANYPARSE_SCRUB_LIST');
		final given: Array<String> = args.options('--private-root');
		final roots: Array<String> = given.length > 0
			? given
			: (Sys.getEnv('ANYPARSE_SCRUB_PRIVATE_ROOTS') ?? '').split(':').filter(root -> root != '');
		final range: Null<String> = args.option('--range');
		final prePush: Bool = args.flag('--pre-push');
		args.done();
		if (prePush && range != null) throw new UsageError('pass --range or --pre-push, not both');
		if ((list == null || list == '') && roots.length == 0) {
			Sys.stderr().writeString(
				'scrub-guard: no token list (--list / ANYPARSE_SCRUB_LIST) and no private root '
				+ '(--private-root / ANYPARSE_SCRUB_PRIVATE_ROOTS), nothing checked\n'
			);
			return 0;
		}
		for (n => root in roots) if (!FileSystem.exists(root) || !FileSystem.isDirectory(root)) {
			Sys.stderr().writeString('scrub-guard: private root ${n + 1} is not a directory\n');
			return 2;
		}
		var rules: Array<Rule> = [];
		if (list != null && list != '') {
			if (!isFile(list)) {
				Sys.stderr().writeString('scrub-guard: token list $list does not exist\n');
				return 2;
			}
			rules = loadRules(sys.io.File.getContent(list));
		}
		final privates: Array<PathIndex> = [for (root in roots) new PathIndex(privateFiles(root))];
		if (prePush) return pushed(js.Syntax.code("require('fs').readFileSync(0, 'utf8')"), rules, privates, quiet);
		final rows: Array<String> = range == null
			? scanTree(rules, Sys.getCwd(), privates)
			: scanRange(range, rules, Sys.getCwd(), privates);
		report(rows, rules, privates, quiet);
		return rows.length > 0 ? 1 : 0;
	}

	/**
	 * The ranges a push of git's pre-push `stdin` publishes, read in `root`: a deleted ref none; an updated one from the remote's
	 * commit; a new one from below the oldest commit no remote-tracking ref holds — a null range when that commit is a root.
	 */
	public static function pushRanges(stdin: String, root: String): Array<PushRange> {
		final zero: EReg = ~/^0+$/;
		final ranges: Array<PushRange> = [];
		for (line in stdin.split('\n')) {
			final fields: Array<String> = ~/\s+/g.split(line.trim());
			if (fields.length < 4 || zero.match(fields[1])) continue;
			final local: String = fields[0];
			final sha: String = fields[1];
			if (!zero.match(fields[3])) {
				ranges.push({ local: local, remote: fields[2], range: '${fields[3]}..$sha' });
				continue;
			}
			final unheld: Array<String> = cmd('git rev-list $sha --not --remotes').at(root).lines();
			if (unheld.length == 0) continue;
			final parent: devkit.Result = cmd('git rev-parse --verify --quiet ${unheld[unheld.length - 1]}^').at(root).run();
			ranges.push({ local: local, remote: fields[2], range: parent.ok ? '${parent.out.trim()}..$sha' : null });
		}
		return ranges;
	}

	/** The rules of a filter-repo replace-text file: the left-hand side of every line, in file order. */
	public static function loadRules(text: String): Array<Rule> {
		final rules: Array<Rule> = [];
		final lines: Array<String> = text.split('\n');
		// the line after the last line break is a line only when it holds something, as a file read line by line has it
		if (lines[lines.length - 1] == '') lines.pop();
		for (raw in lines) {
			var line: String = trimLineEnd(raw);
			final arrow: Int = line.lastIndexOf('==>');
			if (arrow >= 0) line = line.substr(0, arrow);
			if (line.startsWith('regex:')) {
				rules.push(Pattern(pattern(line.substr('regex:'.length), rules.length + 1)));
			} else {
				if (line.startsWith('literal:')) line = line.substr('literal:'.length);
				if (line != '') rules.push(Literal(line));
			}
		}
		return rules;
	}

	/**
	 * The regular expression of rule `n`, global so a match can see the text before it (a lookbehind, a `\b`). A leading
	 * Python inline-flag group (`(?i)`, `(?ms)`, …) becomes the expression's flags, since JavaScript has no such group;
	 * any other construct JavaScript cannot compile is a usage error naming the rule.
	 */
	public static function pattern(source: String, n: Int): EReg {
		final flags: EReg = ~/^\(\?([ims]+)\)/;
		final leading: Bool = flags.match(source);
		final options: String = 'g' + (leading ? flags.matched(1) : '');
		final body: String = leading ? source.substr(flags.matchedPos().len) : source;
		return try new EReg(body, options) catch (exception: haxe.Exception) throw new UsageError(
			'rule $n is not a regular expression JavaScript can compile: ${exception.message}'
		);
	}

	/** One `<where>:<line>: rule <n>` row per match of every rule in `data`, rule by rule, each rule's in text order. */
	public static function scan(where: String, data: String, rules: Array<Rule>): Array<String> {
		final rows: Array<String> = [];
		for (n => rule in rules) {
			var line: Int = 1;
			var counted: Int = 0;
			for (start in matchStarts(rule, data)) {
				line += countBreaks(data, counted, start);
				counted = start;
				rows.push('$where:$line: rule ${n + 1}');
			}
		}
		return rows;
	}

	/**
	 * The rows of every file git tracks under the directory `root`, each named relative to it; with `privates`, also
	 * the private-tree rows of `privatePaths`, the tracked files standing for the scanned tree.
	 */
	public static function scanTree(rules: Array<Rule>, root: String, ?privates: Array<PathIndex>): Array<String> {
		final rows: Array<String> = [];
		final tracked: Array<String> = names(cmd('git ls-files -z').at(root).text());
		final own: PathIndex = new PathIndex(tracked);
		for (name in tracked) if (isFile(Path.join([root, name]))) {
			final data: Null<String> = textOf(Path.join([root, name]));
			if (data != null) for (row in scan(name, data, rules).concat(privatePaths(name, data, own, privates ?? []))) rows.push(row);
		}
		return rows;
	}

	/**
	 * The rows of the lines `span` (`A..B`) adds and of its commit messages, in the repository at `root`; with
	 * `privates`, also the private-tree rows of `privatePaths`, the files of `B` standing for the scanned tree.
	 */
	public static function scanRange(span: String, rules: Array<Rule>, root: String, ?privates: Array<PathIndex>): Array<String> {
		final cut: Int = span.indexOf('..');
		if (cut < 0) throw new UsageError('--range needs A..B');
		final base: String = span.substr(0, cut);
		final tip: String = span.substr(cut + 2);
		final added: Array<String> = [
			for (line in cmd('git diff --no-color -U0 $base $tip').at(root).text().split('\n'))
				if (line.startsWith('+') && !line.startsWith('+++')) line.substr(1)
		];
		final messages: String = cmd('git log --format=%H%n%B $base..$tip').at(root).text();
		final trees: Array<PathIndex> = privates ?? [];
		final own: PathIndex = new PathIndex(trees.length == 0 ? [] : names(cmd('git ls-tree -r -z --name-only $tip').at(root).text()));
		final diff: String = 'diff $span';
		final log: String = 'messages $span';
		final lines: String = added.join('\n');
		final rows: Array<String> = scan(diff, lines, rules).concat(privatePaths(diff, lines, own, trees));
		return rows.concat(scan(log, messages, rules)).concat(privatePaths(log, messages, own, trees));
	}

	/**
	 * One `<where>:<line>: private root <k>` row per path-shaped token of `data` that names a file or directory of
	 * `privates[k - 1]` and none of the scanned tree `own` — `namings` says what a token can name, `treeNaming` which
	 * tree names it first. A backslash in a token is read both as a separator and as the start of a string escape.
	 */
	public static function privatePaths(where: String, data: String, own: PathIndex, privates: Array<PathIndex>): Array<String> {
		final rows: Array<String> = [];
		if (privates.length == 0) return rows;
		final token: EReg = ~/[A-Za-z0-9_.\/\\-]+/g;
		var line: Int = 1;
		var counted: Int = 0;
		var from: Int = 0;
		while (from <= data.length && token.matchSub(data, from)) {
			final pos: { pos: Int, len: Int } = token.matchedPos();
			from = pos.pos + pos.len;
			final text: String = token.matched(0);
			final readings: Array<String> = [~/[\/\\]+/g.replace(text, '/')];
			if (text.indexOf('\\') >= 0) for (piece in ~/\\./g.split(text)) readings.push(piece);
			final tree: Int = treeNaming(readings, own, privates);
			if (tree < 0) continue;
			line += countBreaks(data, counted, pos.pos);
			counted = pos.pos;
			rows.push('$where:$line: private root ${tree + 1}');
		}
		return rows;
	}

	/**
	 * The files of the private tree at `root`, relative to it: what git tracks when `root` is the top of a checkout (a
	 * build's output is not the project's text), every regular file under it otherwise — a symbolic link is not followed.
	 */
	public static function privateFiles(root: String): Array<String> {
		if (FileSystem.exists(Path.join([root, '.git']))) return names(cmd('git ls-files -z').at(root).text());
		final files: Array<String> = [];
		walk(root, '', files);
		return files;
	}

	/**
	 * What the token `text` can name, longest first. A path (`/`-separated) names a file by each of its trailing segment
	 * runs, or — its last segment carrying no extension — a directory by each such run. A dotted name (`a.b.X`, no `/`)
	 * names a module, a file of any extension, by each run of its segments, and a directory by each such run; only runs
	 * `distinctive` admits are named. Trailing dots close a sentence, not a name.
	 */
	public static function namings(text: String): Array<Naming> {
		var name: String = text;
		while (name.endsWith('.')) name = name.substr(0, name.length - 1);
		final out: Array<Naming> = [];
		if (name.indexOf('/') >= 0) {
			final segments: Array<String> = name.split('/').filter(segment -> segment != '');
			final file: Bool = segments.length > 0 && hasExtension(segments[segments.length - 1]);
			for (first in 0...segments.length - 1) {
				final run: Array<String> = segments.slice(first);
				if (distinctive(run, !file)) out.push(file ? FilePath(run.join('/')) : DirectoryPath(run.join('/')));
			}
			return out;
		}
		final segments: Array<String> = name.split('.');
		if (segments.length < 2 || !segments.foreach(isIdentifier)) return out;
		var size: Int = segments.length;
		while (size >= 2) {
			for (first in 0...segments.length - size + 1) {
				final run: Array<String> = segments.slice(first, first + size);
				if (distinctive(run, false)) out.push(ModulePath(run.join('/')));
				if (distinctive(run, true)) out.push(DirectoryPath(run.join('/')));
			}
			size--;
		}
		return out;
	}

	/**
	 * The `--pre-push` run: git's pre-push `stdin` (`<local ref> <local sha> <remote ref> <remote sha>` per line), each pushed
	 * range scanned as `--range` scans it (`pushRanges`). A ref reaching a root commit no remote holds has no range and refuses
	 * the push. Answers the exit status.
	 */
	private static function pushed(stdin: String, rules: Array<Rule>, privates: Array<PathIndex>, quiet: Bool): Int {
		final root: String = Sys.getCwd();
		final refused: Array<String> = [];
		var status: Int = 0;
		for (push in pushRanges(stdin, root)) {
			final range: Null<String> = push.range;
			if (range == null) {
				final local: String = push.local;
				Sys.stderr().writeString(
					'pre-push-scrub: $local reaches a root commit no remote holds; run `node bin/dev.js scrub-guard` on that tree by hand\n'
				);
				status = 1;
				continue;
			}
			final rows: Array<String> = scanRange(range, rules, root, privates);
			report(rows, rules, privates, quiet);
			if (rows.length <= 0) continue;
			status = 1;
			refused.push(push.remote);
		}
		if (status != 0) {
			final what: String = refused.length == 0 ? 'the refs above' : refused.join(' ');
			Sys.stderr().writeString('pre-push-scrub: refusing the push of $what: scrub the matches above first\n');
		}
		return status;
	}

	/** Print the match `rows` (unless `quiet`) and the count line on stderr. */
	private static function report(rows: Array<String>, rules: Array<Rule>, privates: Array<PathIndex>, quiet: Bool): Void {
		if (!quiet && rows.length > 0) Sys.println(rows.join('\n'));
		final also: String = privates.length > 0 ? ' and ${privates.length} private root(s)' : '';
		Sys.stderr().writeString('scrub-guard: ${rows.length} match(es) of ${rules.length} rule(s)$also\n');
	}

	/** The offset of every match of `rule` in `data`, non-overlapping, left to right. */
	private static function matchStarts(rule: Rule, data: String): Array<Int> {
		final starts: Array<Int> = [];
		switch rule {
			case Literal(text):
				var at: Int = data.indexOf(text);
				while (at >= 0) {
					starts.push(at);
					at = data.indexOf(text, at + text.length);
				}
			case Pattern(re):
				var from: Int = 0;
				while (from <= data.length && re.matchSub(data, from)) {
					final pos: { pos: Int, len: Int } = re.matchedPos();
					starts.push(pos.pos);
					// an empty match moves on by one, or the scan would stand still
					from = pos.pos + (pos.len == 0 ? 1 : pos.len);
				}
		}
		return starts;
	}

	/** The line breaks in `data` from `from` up to `to`. */
	private static function countBreaks(data: String, from: Int, to: Int): Int {
		var breaks: Int = 0;
		var at: Int = data.indexOf('\n', from);
		while (at >= 0 && at < to) {
			breaks++;
			at = data.indexOf('\n', at + 1);
		}
		return breaks;
	}

	/** Whether `name` is a regular file, following a symbolic link. */
	private static function isFile(name: String): Bool {
		return FileSystem.exists(name) && !FileSystem.isDirectory(name);
	}

	/** The text of the file `name`, or null when it is binary. */
	private static function textOf(name: String): Null<String> {
		final bytes: Buffer = Fs.readFileSync(name);
		return bytes.subarray(0, BINARY_PROBE).indexOf(0) >= 0 ? null : bytes.toString('utf8');
	}

	/** `line` without the line-end characters a line read from a file can end in. */
	private static function trimLineEnd(line: String): String {
		var end: Int = line.length;
		while (end > 0 && (line.charAt(end - 1) == '\r' || line.charAt(end - 1) == '\n')) end--;
		return line.substr(0, end);
	}

	/** Append to `files` every regular file under `root`/`relative`, as a path relative to `root`; `.git` is skipped. */
	private static function walk(root: String, relative: String, files: Array<String>): Void {
		for (name in FileSystem.readDirectory(Path.join([root, relative]))) if (name != '.git') {
			final path: String = relative == '' ? name : '$relative/$name';
			final stats: Stats = Fs.lstatSync(Path.join([root, path]));
			if (stats.isDirectory())
				walk(root, path, files)
			else if (stats.isFile())
				files.push(path);
		}
	}

	/**
	 * The index of the first of `trees` that names what one of `readings` names, or -1: each reading's `namings` are
	 * tried longest first, and one the scanned tree `own` names ends that reading, as the token is the tree's own path.
	 */
	private static function treeNaming(readings: Array<String>, own: PathIndex, trees: Array<PathIndex>): Int {
		for (reading in readings) for (naming in namings(reading)) {
			if (own.knows(naming)) break;
			for (n => tree in trees) if (tree.knows(naming)) return n;
		}
		return -1;
	}

	/** The paths of a git `-z` listing, the empty one after its last NUL dropped. */
	private static function names(listing: String): Array<String> {
		return listing.split('\x00').filter(name -> name != '');
	}

	/**
	 * Whether the trailing segment run `run` says something about the project it names: two or more segments once its
	 * leading `SOURCE_ROOT_NAMES` are dropped, or one whose name is `compound` — a module at the top of a source root
	 * (`src/Main.hx`) is otherwise as common a word as a bare file name. A directory needs `DIRECTORY_SEGMENTS` segments
	 * and two that are no source root's, since a name of one or two directories is rarely a project's own.
	 */
	private static function distinctive(run: Array<String>, directory: Bool): Bool {
		var first: Int = 0;
		while (first < run.length - 1 && SOURCE_ROOT_NAMES.contains(run[first])) first++;
		final kept: Int = run.length - first;
		return directory ? run.length >= DIRECTORY_SEGMENTS && kept >= 2 : kept >= 2 || compound(run[run.length - 1]);
	}

	/** Whether the file or module name `name` (its extension aside) joins two or more words: `TextField`, `XMLParser`, `utf8Decode`. */
	private static function compound(name: String): Bool {
		final dot: Int = name.indexOf('.');
		final stem: String = dot > 0 ? name.substr(0, dot) : name;
		return ~/[a-z0-9][A-Z]|[A-Z][A-Z][a-z]|[A-Za-z][_0-9]|[_0-9][A-Za-z]/.match(stem);
	}

	/** Whether the path segment `segment` ends in an extension: a dot after its first character, then letters and digits. */
	private static function hasExtension(segment: String): Bool {
		return ~/^[A-Za-z0-9_-][A-Za-z0-9_.-]*\.[A-Za-z0-9]+$/.match(segment);
	}

	/** Whether `segment` is an identifier, as each segment of a dotted module path is. */
	private static function isIdentifier(segment: String): Bool {
		return ~/^[A-Za-z_][A-Za-z0-9_]*$/.match(segment);
	}

}

/** One rule of the list: a `Literal` substring, or a `Pattern` (a global regular expression). */
enum Rule {
	Literal(text: String);
	Pattern(re: EReg);
}

/**
 * What a token of the scanned text can name in a tree, by trailing path: a
 * `FilePath`, a `ModulePath` (a file of any extension) or a `DirectoryPath`.
 */
enum Naming {
	FilePath(path: String);
	ModulePath(path: String);
	DirectoryPath(path: String);
}

/** The files of one tree, with their module paths and directories, by base name: answers whether a `Naming` names one. */
@:nullSafety(Strict)
final class PathIndex {

	private final _files: Map<String, Array<String>> = [];

	/** Each file's path without its extension. */
	private final _modules: Map<String, Array<String>> = [];

	private final _directories: Map<String, Array<String>> = [];

	public function new(files: Array<String>) {
		for (file in files) {
			add(_files, file);
			final cut: Int = file.lastIndexOf('/');
			final dot: Int = file.lastIndexOf('.');
			if (dot > cut + 1) add(_modules, file.substr(0, dot));
			var directory: String = file;
			var at: Int = cut;
			// a directory already held came with every directory above it
			while (at > 0) {
				directory = directory.substr(0, at);
				if (!add(_directories, directory)) break;
				at = directory.lastIndexOf('/');
			}
		}
	}

	/** Whether `naming` is one of the tree's files, module paths or directories, or the trailing whole segments of one. */
	public function knows(naming: Naming): Bool {
		return switch naming {
			case FilePath(path): holds(_files, path);
			case ModulePath(path): holds(_modules, path);
			case DirectoryPath(path): holds(_directories, path);
		}
	}

	private static inline function baseName(path: String): String {
		return path.substr(path.lastIndexOf('/') + 1);
	}

	/** Add `path` under its base name unless it is there already; answers whether it was added. */
	private static function add(byName: Map<String, Array<String>>, path: String): Bool {
		final name: String = baseName(path);
		final same: Null<Array<String>> = byName[name];
		if (same == null) {
			byName[name] = [path];
			return true;
		}
		if (same.contains(path)) return false;
		same.push(path);
		return true;
	}

	private static function holds(byName: Map<String, Array<String>>, path: String): Bool {
		final same: Null<Array<String>> = byName[baseName(path)];
		return same != null && same.exists(held -> held == path || held.endsWith('/$path'));
	}

}

/** One ref of a push: its local and remote names and the commits it publishes, or a null range when no remote holds a base. */
typedef PushRange = {
	var local: String;
	var remote: String;
	var range: Null<String>;
}

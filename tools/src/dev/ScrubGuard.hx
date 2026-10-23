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
 * `dev scrub-guard [--list PATH] [--private-root DIR]... [--range A..B] [--quiet]` — fails when text a downstream project
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
 * path-shaped token that names one of its files and none of the scanned tree's is a match too, printed as
 * `<where>:<line>: private root <k>` — the structural half, for the path no list entry spells (`privatePaths`).
 *
 * Exit 0 = clean, or nothing configured (said on stderr, so a clone without the private list is not blocked); 1 = a
 * match; 2 = a usage error, or a scan that could not run.
 */
@:nullSafety(Strict)
final class ScrubGuard {

	public static inline final USAGE: String = 'usage: dev scrub-guard [--list PATH] [--private-root DIR]... [--range A..B] [--quiet]';

	/** How many leading bytes of a file are looked at for a NUL before it counts as binary. */
	private static inline final BINARY_PROBE: Int = 8192;

	/** Directory names a project keeps its modules under, which say nothing about the project. */
	private static final SOURCE_ROOT_NAMES: Array<String> = ['src', 'source', 'lib', 'test', 'tests'];

	/** Run the subcommand over `argv`; answers the exit status. */
	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final quiet: Bool = args.flag('--quiet');
		final list: Null<String> = args.option('--list') ?? Sys.getEnv('ANYPARSE_SCRUB_LIST');
		final given: Array<String> = args.options('--private-root');
		final roots: Array<String> = given.length > 0
			? given
			: (Sys.getEnv('ANYPARSE_SCRUB_PRIVATE_ROOTS') ?? '').split(':').filter(root -> root != '');
		final range: Null<String> = args.option('--range');
		args.done();
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
		final rows: Array<String> = range == null
			? scanTree(rules, Sys.getCwd(), privates)
			: scanRange(range, rules, Sys.getCwd(), privates);
		if (!quiet && rows.length > 0) Sys.println(rows.join('\n'));
		final also: String = roots.length > 0 ? ' and ${roots.length} private root(s)' : '';
		Sys.stderr().writeString('scrub-guard: ${rows.length} match(es) of ${rules.length} rule(s)$also\n');
		return rows.length > 0 ? 1 : 0;
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
	 * One `<where>:<line>: private root <k>` row per path-shaped token of `data` — two or more segments, the last with an
	 * extension — that names a file of `privates[k - 1]` and no file of the scanned tree `own`; a token that is not
	 * `distinctive` does not count. A leading `./` or `../` is dropped, and the first tree that names the path takes the row.
	 */
	public static function privatePaths(where: String, data: String, own: PathIndex, privates: Array<PathIndex>): Array<String> {
		final rows: Array<String> = [];
		if (privates.length == 0) return rows;
		final token: EReg = ~/(?<![A-Za-z0-9_.\/-])(?:[A-Za-z0-9_.-]+\/)+[A-Za-z0-9_-][A-Za-z0-9_.-]*\.[A-Za-z0-9]+/g;
		var line: Int = 1;
		var counted: Int = 0;
		var from: Int = 0;
		while (from <= data.length && token.matchSub(data, from)) {
			final pos: { pos: Int, len: Int } = token.matchedPos();
			from = pos.pos + pos.len;
			final path: String = relativePart(token.matched(0));
			final tree: Int = !distinctive(path) || own.names(path) ? -1 : firstNaming(privates, path);
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

	/** `path` without its leading `./` and `../` segments. */
	private static function relativePart(path: String): String {
		var rest: String = path;
		while (rest.startsWith('./') || rest.startsWith('../')) rest = rest.substr(rest.indexOf('/') + 1);
		return rest;
	}

	/** The index of the first of `trees` that names `path`, or -1. */
	private static function firstNaming(trees: Array<PathIndex>, path: String): Int {
		for (n => tree in trees) if (tree.names(path)) return n;
		return -1;
	}

	/** The paths of a git `-z` listing, the empty one after its last NUL dropped. */
	private static function names(listing: String): Array<String> {
		return listing.split('\x00').filter(name -> name != '');
	}

	/**
	 * Whether `path` still holds a directory once its leading `SOURCE_ROOT_NAMES` segments are dropped: a module at the
	 * top of a source root (`src/Main.hx`) carries no package, so it is as common a word as a bare file name.
	 */
	private static function distinctive(path: String): Bool {
		final segments: Array<String> = path.split('/');
		var first: Int = 0;
		while (first < segments.length - 1 && SOURCE_ROOT_NAMES.contains(segments[first])) first++;
		return segments.length - first >= 2;
	}

}

/** One rule of the list: a `Literal` substring, or a `Pattern` (a global regular expression). */
enum Rule {
	Literal(text: String);
	Pattern(re: EReg);
}

/** The files of one tree by base name: answers whether a relative path names one of them. */
@:nullSafety(Strict)
final class PathIndex {

	private final _byName: Map<String, Array<String>> = [];

	public function new(files: Array<String>) {
		for (file in files) {
			final name: String = baseName(file);
			final same: Null<Array<String>> = _byName[name];
			if (same == null)
				_byName[name] = [file]
			else
				same.push(file);
		}
	}

	/** Whether `path` is one of the files, or the trailing whole segments of one. */
	public function names(path: String): Bool {
		final same: Null<Array<String>> = _byName[baseName(path)];
		return same != null && same.exists(file -> file == path || file.endsWith('/$path'));
	}

	private static inline function baseName(path: String): String {
		return path.substr(path.lastIndexOf('/') + 1);
	}

}

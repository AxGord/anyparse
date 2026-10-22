package dev;

import devkit.Args;
import devkit.Cmd.cmd;
import haxe.io.Path;
import js.node.Buffer;
import js.node.Fs;
import sys.FileSystem;

using StringTools;

/**
 * `dev scrub-guard [--list PATH] [--range A..B] [--quiet]` — fails when text a downstream project must not see published
 * is about to enter the repository.
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
 * Exit 0 = clean, or no list configured (said on stderr, so a clone without the private list is not blocked); 1 = a
 * match; 2 = a usage error, or a scan that could not run.
 */
@:nullSafety(Strict)
final class ScrubGuard {

	public static inline final USAGE: String = 'usage: dev scrub-guard [--list PATH] [--range A..B] [--quiet]';

	/** How many leading bytes of a file are looked at for a NUL before it counts as binary. */
	private static inline final BINARY_PROBE: Int = 8192;

	/** Run the subcommand over `argv`; answers the exit status. */
	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final quiet: Bool = args.flag('--quiet');
		final list: Null<String> = args.option('--list') ?? Sys.getEnv('ANYPARSE_SCRUB_LIST');
		final range: Null<String> = args.option('--range');
		args.done();
		if (list == null || list == '') {
			Sys.stderr().writeString('scrub-guard: no token list (--list / ANYPARSE_SCRUB_LIST), nothing checked\n');
			return 0;
		}
		if (!isFile(list)) {
			Sys.stderr().writeString('scrub-guard: token list $list does not exist\n');
			return 2;
		}
		final rules: Array<Rule> = loadRules(sys.io.File.getContent(list));
		final rows: Array<String> = range == null ? scanTree(rules, Sys.getCwd()) : scanRange(range, rules, Sys.getCwd());
		if (!quiet && rows.length > 0) Sys.println(rows.join('\n'));
		Sys.stderr().writeString('scrub-guard: ${rows.length} match(es) of ${rules.length} rule(s)\n');
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

	/** The rows of every file git tracks under the directory `root`, each named relative to it. */
	public static function scanTree(rules: Array<Rule>, root: String): Array<String> {
		final rows: Array<String> = [];
		for (name in cmd('git ls-files -z').at(root).text().split('\x00')) if (name != '' && isFile(Path.join([root, name]))) {
			final data: Null<String> = textOf(Path.join([root, name]));
			if (data != null) for (row in scan(name, data, rules)) rows.push(row);
		}
		return rows;
	}

	/** The rows of the lines `span` (`A..B`) adds and of its commit messages, in the repository at `root`. */
	public static function scanRange(span: String, rules: Array<Rule>, root: String): Array<String> {
		final cut: Int = span.indexOf('..');
		if (cut < 0) throw new UsageError('--range needs A..B');
		final base: String = span.substr(0, cut);
		final tip: String = span.substr(cut + 2);
		final added: Array<String> = [
			for (line in cmd('git diff --no-color -U0 $base $tip').at(root).text().split('\n'))
				if (line.startsWith('+') && !line.startsWith('+++')) line.substr(1)
		];
		final messages: String = cmd('git log --format=%H%n%B $base..$tip').at(root).text();
		return scan('diff $span', added.join('\n'), rules).concat(scan('messages $span', messages, rules));
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

}

/** One rule of the list: a `Literal` substring, or a `Pattern` (a global regular expression). */
enum Rule {
	Literal(text: String);
	Pattern(re: EReg);
}

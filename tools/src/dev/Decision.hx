package dev;

import devkit.Args;
import haxe.Exception;
import haxe.io.Path;
import js.node.Buffer;
import js.node.Fs;
import sys.FileSystem;

using StringTools;

/**
 * `dev decision --slice <ID> <text>` — the only writer of `docs/decisions.md`: appends ONE line `- <text> → <ID>` without
 * reading the file, which has grown past what an agent can afford to open. `problem` and `entryProblem` are the shape every
 * new line keeps, and `addedLines` what a slice added; `dev slice-gate` checks the second with the first.
 */
@:nullSafety(Strict)
final class Decision {

	public static inline final USAGE: String = 'usage: dev decision --slice <ID> <text> [--repo <dir>]';

	/** The ledger, relative to the tree. */
	public static inline final LEDGER: String = 'docs/decisions.md';

	/** The longest text a line may carry: one sentence, what was tried and why not; the detail is the slice's commit. */
	public static inline final MAX_TEXT: Int = 300;

	/** What separates a line's text from the slice that decided it. */
	private static inline final ARROW: String = ' → ';

	/** The line that ends the ledger's header; the lines are below it. */
	private static inline final HEADER_END: String = '---';

	/** A slice id as the queue spells it: `PROC-1`, `FB-2b`. */
	private static final SLICE_ID: EReg = ~/^[A-Z][A-Za-z0-9]*(-[A-Za-z0-9]+)*$/;

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final slice: Null<String> = args.option('--slice');
		final repo: String = Repo.resolve(args.option('--repo'));
		final text: String = args.positionals(['<text>'])[0];
		if (slice == null) throw new UsageError('missing --slice <ID>');
		final why: Null<String> = problem(text, slice);
		if (why != null) throw new UsageError('refused: $why');
		final line: String = '- $text$ARROW$slice';
		append(Path.join([repo, LEDGER]), line);
		Sys.println(line);
		return 0;
	}

	/** Append `line` to `file`, starting a new line first when the file does not end in one; reads only its last byte. */
	public static function append(file: String, line: String): Void {
		if (!FileSystem.exists(file)) throw new Exception('$file does not exist');
		final size: Int = FileSystem.stat(file).size;
		var lead: String = '';
		if (size > 0) {
			final last: Buffer = Buffer.alloc(1);
			final fd: Int = Fs.openSync(file, 'r');
			Fs.readSync(fd, last, 0, 1, size - 1);
			Fs.closeSync(fd);
			if (last[0] != '\n'.code) lead = '\n';
		}
		// not `sys.io.File.append`: on node it writes from offset 0, over the head of the file
		Fs.appendFileSync(file, '$lead$line\n');
	}

	/** Why `text` decided by `slice` cannot be a ledger line, or null when it can. */
	public static function problem(text: String, slice: String): Null<String> {
		if (!SLICE_ID.match(slice)) return 'the slice id `$slice` is not an id like PROC-1 or FB-2b';
		if (text.indexOf('\n') >= 0 || text.indexOf('\r') >= 0) return 'the text spans several lines — a decision is one line';
		if (text.trim() == '') return 'the text is empty';
		final arrow: Int = text.lastIndexOf(ARROW);
		if (arrow >= 0 && SLICE_ID.match(text.substr(arrow + ARROW.length)))
			return 'the text already ends in `→ <ID>` — pass the id with --slice only';
		if (text.length > MAX_TEXT)
			return 'the text is ${text.length} characters, over $MAX_TEXT — one sentence; the detail is the commit message';
		return null;
	}

	/** Why `line`, added to the ledger, is not a line `dev decision` would write, or null when it is. */
	public static function entryProblem(line: String): Null<String> {
		if (!line.startsWith('- ')) return 'not a `- … → <ID>` line (a continuation, or free text)';
		final arrow: Int = line.lastIndexOf(ARROW);
		return arrow < 0 ? 'does not end with `→ <ID>`' : problem(line.substring('- '.length, arrow), line.substr(arrow + ARROW.length));
	}

	/**
	 * The lines of the ledger `now` below its header that `base` does not hold, as a multiset (a union merge may reorder,
	 * never remove); blank lines and section headings are not lines a decision is written in, so they are left out.
	 */
	public static function addedLines(base: String, now: String): Array<String> {
		final old: Map<String, Int> = [];
		for (line in body(base)) old[line] = (old[line] ?? 0) + 1;
		final added: Array<String> = [];
		for (line in body(now)) {
			final left: Int = old[line] ?? 0;
			if (left > 0)
				old[line] = left - 1
			else if (line.trim() != '' && !(line.startsWith('#') && line.length <= MAX_TEXT))
				added.push(line);
		}
		return added;
	}

	/** The lines of `ledger` below its header, all of it when there is no header. */
	private static function body(ledger: String): Array<String> {
		final lines: Array<String> = ledger.split('\n');
		final end: Int = lines.indexOf(HEADER_END);
		return end < 0 ? lines : lines.slice(end + 1);
	}

}

package dev;

import anyparse.grammar.json.JsonFormat;
import dev.QueueFile.QueueLine;
import devkit.Args;
import devkit.Cmd.cmd;
import devkit.Result;
import haxe.Exception;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/** What `SplitApply.check` makes of a delivered list: the lines to add, the parent's priority filled in, or every reason it is refused. */
typedef SplitVerdict = { final lines: Array<SplitLineJson>; final problems: Array<String>; }

/**
 * `dev split-apply <ID> --lines <file>` — the one answer to "may this delivered list of queue lines replace the running line
 * <ID>, and is it added": checks what the queue CLI does not (touched paths exist or are marked `(new)`, a difficulty on
 * every line, the parent's user quotes copied into every text, an open line on the same owner or touches named in `after:`
 * or in the text), then adds the whole list through the queue CLI's batch add with the split mark, which also refuses it
 * whole. A refused list writes nothing.
 */
final class SplitApply {

	/** The list was refused, by this check or by the queue CLI: the output names every reason. */
	public static inline final EXIT_REFUSED: Int = 1;

	public static final USAGE: String =
		'usage: dev split-apply <ID> --lines <file> [--repo <dir>] [--queue <file>] [--record <file>] [--queue-cli <script>] [--dry-run]';

	/** A user quote of a line's text: the words a split must carry into every new line. */
	private static final QUOTE: EReg = ~/«[^»]*»/;

	private static final OPEN: Array<String> = ['pending', 'backlog', 'running'];

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final lines: Null<String> = args.option('--lines');
		final repo: String = Repo.resolve(args.option('--repo'));
		final queue: String = args.option('--queue') ?? Path.join([repo, '.claude/batch/queue.yaml']);
		final script: String = args.option('--queue-cli') ?? LessonsFile.queueCli();
		final dryRun: Bool = args.flag('--dry-run');
		final record: Null<String> = args.option('--record');
		final id: String = args.positionals(['<ID>'])[0];
		if (lines == null) throw new UsageError('missing --lines <file>');
		final verdict: SplitVerdict = check(id, File.getContent(lines), File.getContent(queue), repo);
		if (verdict.problems.length > 0) {
			Sys.println('split of $id refused, nothing written (${verdict.problems.length} problem(s)):');
			for (problem in verdict.problems) Sys.println('  $problem');
			return EXIT_REFUSED;
		}
		final out: String = record ?? '${Path.withoutExtension(lines)}.applied.json';
		File.saveContent(out, SplitLinesJsonWriter.write({ tasks: verdict.lines }, JsonFormat.instance.compactWriteOptions));
		if (dryRun) {
			Sys.println(File.getContent(out).trim());
			return 0;
		}
		final run: Result = cmd('$script $queue --add-batch $out --split $id').run();
		if (!run.ok) {
			FileSystem.deleteFile(out);
			Sys.println('split of $id refused by the queue CLI: ${run.err.trim()}');
			return EXIT_REFUSED;
		}
		Sys.println(summary(id, verdict.lines));
		return 0;
	}

	/** The one line the parent reads for an applied split: `SPLIT <ID> -> <new ids>`. */
	public static function summary(id: String, lines: Array<SplitLineJson>): String {
		return 'SPLIT $id -> ${lines.map(line -> line.id).join(', ')}';
	}

	/** Every reason the delivered list (a JSON list of lines) may not replace line `id` of the queue text, or the lines to add. */
	public static function check(id: String, delivered: String, queue: String, repo: String): SplitVerdict {
		final parent: Null<QueueLine> = QueueFile.find(queue, id);
		if (parent == null) return refused('no line $id in the queue');
		var error: String = '';
		final parsed: Null<SplitLinesJson> = try {
			SplitLinesJsonParser.parse('{"tasks": ${delivered.trim()}}');
		} catch (exception: Exception) {
			error = exception.message;
			null;
		}
		if (parsed == null) return refused('split_lines is not a JSON list of lines in the queue task shape: $error');
		if (parsed.tasks.length == 0) return refused('split_lines is an empty list');
		final ids: Array<String> = parsed.tasks.map(line -> line.id);
		final open: Array<QueueLine> = QueueFile.read(queue)
			.filter(line -> OPEN.contains(line.status) && line.id != id && !ids.contains(line.id));
		final quotes: Array<String> = quotesOf(parent.text);
		final problems: Array<String> = [
			for (line in parsed.tasks) for (problem in lineProblems(line, id, quotes, open, repo)) '${line.id}: $problem'
		];
		return { lines: problems.length > 0 ? [] : parsed.tasks.map(line -> inherit(line, parent.priority)), problems: problems };
	}

	private static function lineProblems(
		line: SplitLineJson, id: String, quotes: Array<String>, open: Array<QueueLine>, repo: String
	): Array<String> {
		final problems: Array<String> = [];
		if (line.id == id) problems.push('the id is the parent line\'s own');
		if (line.difficulty == null) problems.push('no difficulty');
		if (line.touches.length == 0) problems.push('no touches');
		for (entry in line.touches) {
			final problem: Null<String> = LessonsFile.pathProblem(entry, repo);
			if (problem != null) problems.push(problem);
		}
		for (quote in quotes) if (!line.text.contains(quote)) problems.push('the text lacks the parent\'s quote $quote');
		final after: Array<String> = line.after ?? [];
		for (other in open) if (!after.contains(other.id) && !line.text.contains(other.id)) {
			final shared: Null<String> = sharedWith(line, other);
			if (shared != null)
				problems.push(
					'${other.id} (${other.status}) is open on $shared: name it in `after:` when the order matters, else in the text'
				);
		}
		return problems;
	}

	/** What an open line shares with a new one, the owner or a touched path (one inside the other), or null. */
	private static function sharedWith(line: SplitLineJson, other: QueueLine): Null<String> {
		final owner: String = line.owner ?? '';
		if (owner != '' && owner == other.owner) return 'the same owner $owner';
		for (mine in line.touches) for (theirs in other.touches) {
			final a: String = LessonsFile.touched(mine);
			final b: String = LessonsFile.touched(theirs);
			if (a == b || a.startsWith('$b/') || b.startsWith('$a/')) return 'the touched path $a';
		}
		return null;
	}

	private static function inherit(line: SplitLineJson, priority: String): SplitLineJson {
		return line.priority != null || priority == '' ? line : {
			id: line.id,
			difficulty: line.difficulty,
			kind: line.kind,
			priority: priority,
			touches: line.touches,
			owner: line.owner,
			after: line.after,
			text: line.text
		};
	}

	private static function quotesOf(text: String): Array<String> {
		final out: Array<String> = [];
		var rest: String = text;
		while (QUOTE.match(rest)) {
			out.push(QUOTE.matched(0));
			rest = QUOTE.matchedRight();
		}
		return out;
	}

	private static function refused(problem: String): SplitVerdict {
		return { lines: [], problems: [problem] };
	}

}

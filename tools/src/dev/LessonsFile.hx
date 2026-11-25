package dev;

import anyparse.grammar.json.JsonFormat;
import anyparse.util.Compare;
import dev.QueueFile.QueueLine;
import dev.ScrubGuard.Rule;
import devkit.Args;
import devkit.Cmd.cmd;
import devkit.Result;
import haxe.Exception;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/** One lesson of a slice, read from a record file of its logs dir. */
typedef Lesson = {
	final slice: String;
	final id: String;
	final kind: String;
	final touches: Array<String>;
	final repro: String;
	final text: String;
}

/** What `judge` reads besides the lesson: the queue's lines, the tree the touched paths must exist in, the private-names list. */
typedef LessonWorld = { final queue: Array<QueueLine>; final repo: String; final names: Array<Rule>; }

/** What a logs dir held: its lessons, and one row per record file that could not be read (nothing is dropped). */
typedef LessonBatch = { final lessons: Array<Lesson>; final unreadable: Array<String>; }

/** Where `LessonsFile.file` reads and writes; `names` is the private-names list, whose absence skips that check. */
typedef LessonPaths = {
	final repo: String;
	final queue: String;
	final triage: String;
	final script: String;
	final names: Null<String>;
}

/** What one logs dir came to: lines added, records the queue already holds, and the rows left for the parent. */
typedef LessonReport = {
	final filed: Int;
	final already: Int;
	final triage: Array<String>;
	final namesChecked: Bool;
}

/** What the queue and the tree say about one lesson. */
enum LessonVerdict {

	/** Valid, and of a class that is filed without the parent. */
	Admit;

	/** The queue holds this very lesson from an earlier run. */
	Already;

	/** Not filed: the parent reads the reason. */
	Triage(reason: String);

}

/**
 * `dev lessons-file <logs dir> --slice <ID>` — the one answer to "which lessons of a landed slice become queue lines and
 * which are left for the parent": reads the lesson records of the slice's logs dir, files the obvious ones through the
 * queue CLI (`unverified` as a backlog line of priority low, `arm-rot-on-base` as a pending line of priority high) and
 * appends every other record, and every refused one with its reason, to the triage file. A record is never dropped: it
 * is a queue line, a triage row, or a queue line an earlier run already wrote.
 */
@:nullSafety(Strict)
final class LessonsFile {

	public static inline final USAGE: String =
		'usage: dev lessons-file <logs dir> --slice <ID> [--repo <dir>] [--queue <file>] [--triage <file>] [--queue-cli <script>] [--private-names <file>]';
	public static inline final UNVERIFIED: String = 'unverified';
	public static inline final ARM_ROT: String = 'arm-rot-on-base';

	/** More files than this conflicts with most of the queue, so the line would run alone. */
	public static inline final MAX_TOUCHES: Int = 8;

	public static inline final MAX_TEXT: Int = 2000;

	/** The record files of a logs dir: the worker's, then the reviewer's. */
	public static final FILES: Array<String> = ['lessons.json', 'review-lessons.json'];

	/** The classes of a lesson, as `slice-dispatch.yaml` `collect` words them. */
	public static final CLASSES: Array<String> = [UNVERIFIED, 'reproduced-on-real-tree', 'loss', ARM_ROT, 'process'];

	/** A pending line needs a difficulty; the repair of a rotted arm is a small one. */
	private static inline final ARM_ROT_DIFFICULTY: Int = 4;

	/**
	 * A brief shorter than this is a substring of too many lines to say two lessons are the same.
	 */
	private static inline final MIN_SHARED_BRIEF: Int = 30;

	private static final NEW_MARK: String = ' (new)';
	private static final ID: EReg = ~/^[A-Z][A-Z0-9]*(-[A-Z0-9]+)*$/;
	private static final GLOB: EReg = ~/[*?\[]/;
	private static final OPEN: Array<String> = ['pending', 'backlog', 'running'];

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final slice: Null<String> = args.option('--slice');
		final repo: String = Repo.resolve(args.option('--repo'));
		final paths: LessonPaths = {
			repo: repo,
			queue: args.option('--queue') ?? Path.join([repo, '.claude/batch/queue.yaml']),
			triage: args.option('--triage') ?? Path.join([repo, '.claude/backups/slice-logs/lessons-triage.txt']),
			script: args.option('--queue-cli') ?? queueCli(),
			names: args.option('--private-names') ?? Sys.getEnv('ANYPARSE_SCRUB_LIST')
		};
		final dir: String = args.positionals(['<logs dir>'])[0];
		if (slice == null) throw new UsageError('missing --slice <ID>');
		final report: LessonReport = file(dir, slice, paths);
		if (!report.namesChecked)
			Sys.stderr()
				.writeString('lessons-file: no private-names list (--private-names, or ANYPARSE_SCRUB_LIST), that check was skipped\n');
		Sys.println(summary(report));
		return 0;
	}

	/** File the lessons of `dir` under `slice`, leave the rest as triage rows; never throws for one record's sake. */
	public static function file(dir: String, slice: String, paths: LessonPaths): LessonReport {
		final batch: LessonBatch = read(dir, slice);
		final names: Null<Array<Rule>> = privateRules(paths.names);
		final rows: Array<String> = batch.unreadable.copy();
		var filed: Int = 0;
		var already: Int = 0;
		for (lesson in batch.lessons) {
			final world: LessonWorld = { queue: QueueFile.read(File.getContent(paths.queue)), repo: paths.repo, names: names ?? [] };
			switch judge(lesson, world) {
				case Admit:
					final refused: Null<String> = submit(paths, lesson);
					if (refused == null)
						filed++
					else
						rows.push(triageRow(lesson, refused));
				case Already:
					already++;
				case Triage(reason):
					rows.push(triageRow(lesson, reason));
			}
		}
		final left: Array<String> = appendTriage(paths.triage, slice, rows);
		already += rows.length - left.length;
		return {
			filed: filed,
			already: already,
			triage: left,
			namesChecked: names != null
		};
	}

	/** The one line the pipeline echoes into the driver's report. */
	public static function summary(report: LessonReport): String {
		return 'lessons=filed ${report.filed}, triage ${report.triage.length}' + (report.already > 0 ? ', already ${report.already}' : '');
	}

	/** The lessons of `dir`'s record files; a file that does not parse is one row of `unreadable`, carrying what it said. */
	public static function read(dir: String, slice: String): LessonBatch {
		final lessons: Array<Lesson> = [];
		final unreadable: Array<String> = [];
		for (name in FILES) {
			final path: String = Path.join([dir, name]);
			if (!FileSystem.exists(path)) continue;
			final content: String = File.getContent(path);
			final parsed: Null<LessonRecordsJson> = try {
				LessonRecordsJsonParser.parse(content);
			} catch (exception: Exception) {
				unreadable.push('$name unreadable: ${oneLine(exception.message)} :: ${oneLine(content)}');
				null;
			}
			if (parsed != null) for (record in parsed.lessons) lessons.push({
				slice: slice,
				id: (record.id ?? '').trim(),
				kind: (record.kind ?? '').trim(),
				touches: (record.touches ?? []).map(entry -> entry.trim()),
				repro: (record.repro ?? '').trim(),
				text: (record.text ?? '').trim()
			});
		}
		return { lessons: lessons, unreadable: unreadable };
	}

	/** What becomes of `lesson`: checks run in the order of the reasons a record is refused, the id first. */
	public static function judge(lesson: Lesson, world: LessonWorld): LessonVerdict {
		final shape: Null<String> = shapeProblem(lesson);
		if (shape != null) return Triage(shape);
		final taken: Null<QueueLine> = world.queue.find(line -> line.id == lesson.id);
		if (taken != null) return taken.text == composed(lesson) ? Already : Triage('the id is taken by another line (${taken.status})');
		final why: Null<String> = touchesProblem(lesson.touches, world.repo) ?? namesProblem(lesson, world.names) ?? duplicateProblem(
			lesson, world.queue
		);
		if (why != null) return Triage(why);
		return fileable(lesson.kind) ? Admit : Triage('class ${lesson.kind} is the parent\'s to file');
	}

	/** The row `wf-queue --add` takes for an admitted lesson: backlog and low for `unverified`, pending and high for the rest. */
	public static function mapping(lesson: Lesson): String {
		final unverified: Bool = lesson.kind == UNVERIFIED;
		final row: LessonRowJson = {
			id: lesson.id,
			status: unverified ? 'backlog' : null,
			difficulty: unverified ? null : ARM_ROT_DIFFICULTY,
			kind: 'bug',
			priority: unverified ? 'low' : 'high',
			touches: lesson.touches,
			text: composed(lesson)
		};
		return LessonRowJsonWriter.write(row, JsonFormat.instance.compactWriteOptions);
	}

	/** The text a filed line carries: its origin, the brief and the one-line repro. */
	public static function composed(lesson: Lesson): String {
		return 'Lesson of ${lesson.slice}. ${lesson.text} Repro: ${lesson.repro}';
	}

	public static function queueCli(): String {
		final root: Null<String> = Sys.getEnv('WF_PLUGIN_ROOT');
		return root == null || root == '' ? 'wf-queue' : Path.join([root, 'scripts', 'wf-queue']);
	}

	private static inline function fileable(kind: String): Bool {
		return kind == UNVERIFIED || kind == ARM_ROT;
	}

	private static function shapeProblem(lesson: Lesson): Null<String> {
		return if (!CLASSES.contains(lesson.kind))
			'kind `${lesson.kind}` is none of ${CLASSES.join(' | ')}'
		else if (!ID.match(lesson.id))
			'the id `${lesson.id}` is not an upper-case queue id like PROC-1'
		else if (lesson.text == '')
			'the text is empty'
		else if (lesson.text.length > MAX_TEXT)
			'the text is ${lesson.text.length} characters, over $MAX_TEXT: a lesson is a brief'
		else if (fileable(lesson.kind) && lesson.repro == '')
			'no repro: an unreproduced lesson is filed with its one-line repro'
		else if (lesson.repro.indexOf('\n') >= 0)
			'the repro spans several lines'
		else
			null;
	}

	private static function touchesProblem(touches: Array<String>, repo: String): Null<String> {
		if (touches.length == 0) return 'no touches: a line without them conflicts with every line';
		if (touches.length > MAX_TOUCHES) return '${touches.length} touches, over $MAX_TOUCHES: it would conflict with most lines';
		for (entry in touches) {
			final path: String = touched(entry);
			if (path == '' || path.startsWith('/') || path.split('/').contains('..') || GLOB.match(path))
				return 'touches `$entry` is not a file path relative to the tree';
			if (entry.endsWith(NEW_MARK)) continue;
			final full: String = Path.join([repo, path]);
			if (!FileSystem.exists(full)) return 'touches `$entry` does not exist on main and is not marked (new)';
			if (FileSystem.isDirectory(full)) return 'touches `$entry` is a directory: name the files the line edits';
		}
		return null;
	}

	private static function namesProblem(lesson: Lesson, rules: Array<Rule>): Null<String> {
		final haystack: String = [lesson.id, lesson.text, lesson.repro].concat(lesson.touches).join('\n');
		return ScrubGuard.scan('lesson', haystack, rules).length > 0 ? 'it matches a rule of the private-names list' : null;
	}

	/** An OPEN line with this brief, or one on the same files that backticks one of the same names, is the same lesson. */
	private static function duplicateProblem(lesson: Lesson, queue: Array<QueueLine>): Null<String> {
		final mine: String = fileSet(lesson.touches);
		final names: Array<String> = ReconFacts.backtickedNames(lesson.text);
		final twin: Null<QueueLine> = queue.find(line -> OPEN.contains(line.status) && (
			(lesson.text.length >= MIN_SHARED_BRIEF && line.text.contains(lesson.text))
			|| (fileSet(line.touches) == mine && names.exists(name -> line.text.contains('`$name`')))
		));
		return twin == null ? null : 'possible duplicate of ${twin.id}';
	}

	private static function fileSet(touches: Array<String>): String {
		final paths: Array<String> = touches.map(touched);
		paths.sort(Compare.compareString);
		return paths.join(',');
	}

	private static function touched(entry: String): String {
		return (entry.endsWith(NEW_MARK) ? entry.substr(0, entry.length - NEW_MARK.length) : entry).trim();
	}

	/** Null when the queue CLI added the line, else why it did not (its own message: archived id, unknown key, no lock). */
	private static function submit(paths: LessonPaths, lesson: Lesson): Null<String> {
		final script: String = paths.script;
		final queue: String = paths.queue;
		final row: String = mapping(lesson);
		final run: Result = cmd('$script $queue --add $row').run();
		return run.ok ? null : 'the queue CLI refused it: ${oneLine(run.firstError())}';
	}

	private static function triageRow(lesson: Lesson, reason: String): String {
		final touches: String = lesson.touches.join(', ');
		return '${lesson.id} [${lesson.kind}] $reason :: ${oneLine(lesson.text)} :: repro: ${oneLine(lesson.repro)} :: touches: $touches';
	}

	/**
	 * Append `== <slice>` and the rows its block does not already hold
	 * verbatim; answers the rows it wrote (a rerun adds only what is new).
	 */
	private static function appendTriage(file: String, slice: String, rows: Array<String>): Array<String> {
		final header: String = '== $slice';
		final held: Array<String> = blockRows(file, header);
		final fresh: Array<String> = rows.filter(row -> !held.contains(row));
		if (fresh.length == 0) return fresh;
		if (!FileSystem.exists(file)) File.saveContent(file, '');
		Decision.append(file, [header].concat(fresh).join('\n'));
		return fresh;
	}

	/**
	 * The rules of the private-names list (`dev.ScrubGuard`'s own form), or null
	 * when none is named or it is absent: the check is then skipped and said so.
	 */
	private static function privateRules(file: Null<String>): Null<Array<Rule>> {
		return file == null || !FileSystem.exists(file) ? null : ScrubGuard.loadRules(File.getContent(file));
	}

	private static function oneLine(text: String): String {
		return ~/\s*[\r\n]+\s*/g.replace(text.trim(), ' ');
	}

	/** The rows under every `header` line of the triage file, up to the next `== ` line. */
	private static function blockRows(file: String, header: String): Array<String> {
		final held: Array<String> = [];
		if (!FileSystem.exists(file)) return held;
		var inside: Bool = false;
		for (row in File.getContent(file).split('\n')) {
			if (row.startsWith('== '))
				inside = row == header
			else if (inside)
				held.push(row);
		}
		return held;
	}

}

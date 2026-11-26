package dev;

import anyparse.grammar.json.JEntry;
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueTools;
import anyparse.grammar.json.JValueWriter;
import anyparse.grammar.json.JsonFormat;
import dev.Probe.Kit;
import dev.Probe.Seen;
import sys.io.File;

using Lambda;

/** What becomes of one probe-additions row: nothing to keep, a kit row of its area, or a queue line. */
enum FoldOutcome {

	/** The engine already answers as the row expects. */
	Drop;

	/** The engine's answer deviates from the expected one: the row to append to the area's `kit.json`. */
	ToKit(area: String, row: JValue);

	/** The row cannot be judged or placed: the text of a queue line quoting it. */
	ToQueue(text: String);

}

/** One row's name and what becomes of it. */
typedef Fold = { var name: String; var outcome: FoldOutcome; }

/**
 * `dev probe --row <file>` — the one answer to "what becomes of a probe-additions row on this engine". The file is a probe kit
 * (`dev probe`'s own format: `invocations` with their `files`, `argv`, `note` and the `expect` the row asks for) with an `area`
 * key naming the `test/probes/<area>` kit a deviating row joins. Each row runs through `Probe.observe` and is judged by
 * `Probe.deviations` against its `expect`: no deviation is a `Drop`; a deviation of a row that names a kit area is a `ToKit` row
 * carrying the engine's recorded answer with a `knownDefect`, so the kit holds until the engine moves; anything else (no
 * expected answer, no engine answer, no such area, a name the kit already holds) is a `ToQueue` text.
 */
@:nullSafety(Strict)
final class ProbeFold {

	/** The document key naming the kit area a row joins. */
	private static final AREA_KEY: String = 'area';

	private static final INVOCATIONS_KEY: String = 'invocations';
	private static final FILES_KEY: String = 'files';
	private static final COMMITS_KEY: String = 'commits';

	public static function command(repo: String, engine: String, file: String, threads: Int, oneProcess: Bool): Int {
		for (line in apply(repo, fold(repo, repo, engine, file, threads, oneProcess))) Sys.println(line);
		return 0;
	}

	/** Runs the rows of `file` on `engine` and decides each; writes nothing. */
	public static function fold(shimTree: String, repo: String, engine: String, file: String, threads: Int, oneProcess: Bool): Array<Fold> {
		final kit: Kit = Probe.load(file);
		final seen: Array<Seen> = Probe.observe(shimTree, engine, kit, false, threads, oneProcess);
		return decide(repo, JValueParser.parse(File.getContent(file)), kit, seen);
	}

	/** Decides each row of `document` (the row file, already run: `kit` is its load, `seen` its answers). */
	public static function decide(repo: String, document: JValue, kit: Kit, seen: Array<Seen>): Array<Fold> {
		final area: Null<String> = JValueTools.stringAt(document, AREA_KEY);
		final known: Bool = area != null && Probe.areas(repo).contains(area);
		final held: Array<String> = area != null && known
			? [ for (row in Probe.load(Probe.kitPath(repo, area)).invocations) row.name ]
			: [];
		final rows: Array<JValue> = JValueTools.items(JValueTools.field(document, INVOCATIONS_KEY));
		final folds: Array<Fold> = [];
		for (i => invocation in kit.invocations) {
			final lines: Array<String> = Probe.deviations(kit.cases[i].expect, seen[i], false);
			final reason: Null<String> = unplaced(area, known, held, invocation.name, kit.cases[i].expect, seen[i], lines);
			if (reason != null) {
				final text: String = quote(invocation.argv, JValueTools.stringAt(rows[i], 'note'), area, seen[i], reason);
				folds.push({ name: invocation.name, outcome: ToQueue(text) });
			} else if (area == null || lines.length == 0) {
				folds.push({ name: invocation.name, outcome: Drop });
			} else {
				held.push(invocation.name);
				folds.push({ name: invocation.name, outcome: ToKit(area, kitRow(rows[i], document, seen[i], lines)) });
			}
		}
		return folds;
	}

	/** Writes each `ToKit` row into its area's kit and returns one report line per row. */
	public static function apply(repo: String, folds: Array<Fold>): Array<String> {
		final report: Array<String> = [];
		for (fold in folds) switch fold.outcome {
			case Drop:
				report.push('DROP ${fold.name}');
			case ToKit(area, row):
				append(Probe.kitPath(repo, area), row);
				report.push('KIT ${fold.name} -> ${Probe.KITS}/$area/${Probe.KIT_FILE}');
			case ToQueue(text):
				report.push('QUEUE ${fold.name}: $text');
		}
		return report;
	}

	/** The JSON edit `Probe.write` makes, adding one row at the end of the kit's `invocations`. */
	public static function append(kitFile: String, row: JValue): Void {
		final kit: JValue = JValueParser.parse(File.getContent(kitFile));
		final text: String = JValueWriter.write(withRow(kit, row), JsonFormat.instance.tabbedWriteOptions);
		File.saveContent(kitFile, '$text\n');
	}

	/** Why the row cannot become a kit row or a drop, null when its answer decides. */
	private static function unplaced(
		area: Null<String>, known: Bool, held: Array<String>, name: String, expected: Null<Expectation>, seen: Seen, lines: Array<String>
	): Null<String> {
		if (seen.failure != '') return 'the engine gave no answer: ${seen.failure}';
		if (expected == null) return 'the row carries no expected answer';
		if (lines.length == 0) return null;
		if (area == null || !known) return 'no kit area ${area ?? '(the row file names none)'} under ${Probe.KITS}';
		return held.contains(name) ? 'the kit of $area already holds a row named $name' : null;
	}

	private static function quote(argv: Array<String>, note: Null<String>, area: Null<String>, seen: Seen, reason: String): String {
		final why: String = note == null ? '' : ' — $note';
		return 'Probe row `${argv.join(' ')}` (area ${area ?? 'none'})$why. Not folded: $reason. '
			+ 'The engine answered exit ${seen.answer.exit}, stdout ${Probe.firstLine(seen.out)}, stderr ${Probe.firstLine(seen.err)}.';
	}

	/** The row as the kit keeps it: self-contained, recording the engine's answer, and marked as a known defect. */
	private static function kitRow(row: JValue, document: JValue, seen: Seen, lines: Array<String>): JValue {
		final recorded: JValue = Probe.withExpectation(row, seen.answer);
		return switch recorded {
			case JObject(entries):
				final defect: JEntry = JValueTools.entry('knownDefect', JString('expected answer not met: ' + lines.join('; ')));
				JObject(put(withFiles(entries, document), defect));
			case _: recorded;
		}
	}

	/**
	 * A row naming neither `files` nor `commits` ran in the row file's shared files, which the kit's own would replace: the row
	 * carries the files it was observed with, an empty set when the document had none.
	 */
	private static function withFiles(entries: Array<JEntry>, document: JValue): Array<JEntry> {
		return entries.exists(entry -> entry.key == FILES_KEY || entry.key == COMMITS_KEY)
			? entries
			: entries.concat([
				JValueTools.entry(FILES_KEY, JValueTools.field(document, FILES_KEY) ?? JObject([]))
			]);
	}

	private static function put(entries: Array<JEntry>, value: JEntry): Array<JEntry> {
		final replaced: Array<JEntry> = entries.map(entry -> entry.key == value.key ? value : entry);
		return entries.exists(entry -> entry.key == value.key) ? replaced : replaced.concat([value]);
	}

	private static function withRow(kit: JValue, row: JValue): JValue {
		return switch kit {
			case JObject(entries):
				final held: Array<JValue> = JValueTools.items(JValueTools.field(kit, INVOCATIONS_KEY));
				JObject(put(entries, JValueTools.entry(INVOCATIONS_KEY, JArray(held.concat([row])))));
			case _: kit;
		}
	}

}

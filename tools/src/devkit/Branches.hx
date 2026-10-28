package devkit;

import devkit.Summary;
import haxe.Json;
import sys.FileSystem;
import sys.io.File;

using Lambda;

/**
 * The steps of a tool's run split into branches that run at once, each a process of the tool: a branch records its steps
 * in a `Summary` of its own and leaves them, with any counts it read, as a report file (`leave`); `run` starts every
 * branch, waits for all of them and adds their steps to the caller's table in table order. A step whose branch ended
 * without reporting it is `NotRun`, and so is one whose report names another run: a branch an earlier run left behind
 * may still write under the same name.
 */
@:nullSafety(Strict)
final class Branches {

	/** How long the reason of a step whose branch left no report may grow. */
	private static inline final WHY_WIDTH: Int = 100;

	/** The bound of a run id's random part. */
	private static inline final NONCE_BOUND: Int = 0x7fffffff;

	/**
	 * Run every branch of `branches` as the process `command` makes of its steps, which leaves its report for the run `id`
	 * at `report(steps)`; add the steps to `into` in `order` and answer the counts the branches read.
	 */
	public static function run(
		id: String, branches: Array<Array<String>>, order: Array<String>, command: Array<String> -> Command,
		report: Array<String> -> String, into: Summary
	): Map<String, Int> {
		for (names in branches) if (FileSystem.exists(report(names))) FileSystem.deleteFile(report(names));
		final runs: Array<Result> = Pool.of(branches.length).map(branches, command);
		final readings: Map<String, Int> = [];
		final steps: Map<String, Step> = [];
		for (i => names in branches) {
			final file: String = report(names);
			final ran: Result = runs[i];
			File.saveContent('$file.log', ran.out + ran.err + ran.failure);
			final left: Null<BranchReport> = reportOf(file, id);
			if (left != null) for (name => value in left.readings) readings[name] = value;
			final why: String = ran.firstError();
			for (name in names) steps[name] = left?.steps.find(s -> s.name == name) ?? {
				name: name,
				outcome: NotRun('its branch left no report: ${why.length > WHY_WIDTH ? why.substr(0, WHY_WIDTH) + '…' : why} — $file.log'),
				ms: 0,
				note: ''
			};
		}
		for (name in order) {
			final step: Null<Step> = steps[name];
			if (step != null) into.add(step.name, step.outcome, step.ms, step.note);
		}
		return readings;
	}

	/** Leave the steps of `summary` and `readings` at `file` for the run `id` that started this branch. */
	public static function leave(file: String, id: String, summary: Summary, readings: Map<String, Int>): Void {
		File.saveContent(file, encode(id, summary.steps(), readings));
	}

	/** The report at `file` when a branch of the run `id` left it, else null — a report of another run is none. */
	public static function reportOf(file: String, id: String): Null<BranchReport> {
		if (!FileSystem.exists(file)) return null;
		final left: BranchReport = decode(File.getContent(file));
		return left.run == id ? left : null;
	}

	/** An id no other run of a tool on this machine shares, for its branches to name in their reports. */
	public static function newRunId(): String {
		return '${js.Node.process.pid}-${Date.now().getTime()}-${Std.random(NONCE_BOUND)}';
	}

	/** `steps` and `readings` of the run `id` as the JSON of a branch report. */
	public static function encode(id: String, steps: Array<Step>, readings: Map<String, Int>): String {
		final rows: Array<StepRecord> = [
			for (step in steps) {
				final kind: Array<String> = switch step.outcome {
					case Passed: ['passed', ''];
					case Failed(why): ['failed', why];
					case NotRun(why): ['not run', why];
					case Skipped(why): ['skipped', why];
				};
				{
					name: step.name,
					outcome: kind[0],
					why: kind[1],
					ms: step.ms,
					note: step.note
				};
			}
		];
		final counts: Array<Reading> = [for (name => value in readings) { name: name, value: value }];
		return Json.stringify({ run: id, steps: rows, readings: counts }, null, '\t');
	}

	/** The steps and readings of the branch report `text`, as `encode` wrote them. */
	public static function decode(text: String): BranchReport {
		final parsed: { ?run: String, steps: Array<StepRecord>, readings: Array<Reading> } = Json.parse(text);
		return {
			run: parsed.run ?? '',
			steps: [
				for (row in parsed.steps)
					{
						name: row.name,
						outcome: switch row.outcome {
							case 'passed': Passed;
							case 'failed': Failed(row.why);
							case 'skipped': Skipped(row.why);
							case _: NotRun(row.why);
						},
						ms: row.ms,
						note: row.note
					}
			],
			readings: [for (reading in parsed.readings) reading.name => reading.value]
		};
	}

	/** What `budget` leaves beside the `held` threads, at least one; null without a budget. */
	public static function share(budget: Null<Int>, held: Int): Null<Int> {
		return budget == null ? null : Std.int(Math.max(1, budget - held));
	}

}

/** What a branch leaves for the run that started it: its steps, and the counts it read. */
typedef BranchReport = {
	/** The run whose branch left it; empty in a report that names none. */
	var run: String;

	var steps: Array<Step>;
	var readings: Map<String, Int>;
}

/** One step of a branch report, its outcome spelled as a label and a reason. */
typedef StepRecord = {
	var name: String;
	var outcome: String;
	var why: String;
	var ms: Float;
	var note: String;
}

/** One count a branch read, by its name. */
typedef Reading = {
	var name: String;
	var value: Int;
}

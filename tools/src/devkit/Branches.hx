package devkit;

import anyparse.grammar.json.JsonFormat;
import devkit.Lease.Ask;
import devkit.Lease.LeaseMode;
import devkit.Reading;
import devkit.StepRecord;
import devkit.Summary;
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

	/** Milliseconds in a second. */
	private static inline final MS_PER_SECOND: Float = 1000;

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
		final spawned: Float = Date.now().getTime();
		final runs: Array<Result> = Pool.of(branches.length).map(branches, command);
		final readings: Map<String, Int> = [];
		final steps: Map<String, Step> = [];
		var longest: Float = 0;
		for (i => names in branches) {
			final file: String = report(names);
			final ran: Result = runs[i];
			File.saveContent('$file.log', ran.out + ran.err + ran.failure);
			final left: Null<BranchReport> = reportOf(file, id);
			final began: Null<Float> = left?.started;
			if (began != null) {
				final waited: Float = waitedMs(spawned, began);
				into.wait(names[0], waited);
				longest = Math.max(longest, waited);
			}
			if (left != null) for (name => value in left.readings) readings[name] = value;
			final why: String = reasonOf(ran);
			for (name in names) steps[name] = left?.steps.find(s -> s.name == name) ?? {
				name: name,
				outcome: NotRun('its branch left no report: $why — $file.log'),
				ms: 0,
				note: '',
				excerpt: Excerpt.errors(ran.out + ran.err + ran.failure)
			};
		}
		for (name in order) {
			final step: Null<Step> = steps[name];
			if (step != null) into.add(step.name, step.outcome, step.ms, step.note, step.excerpt);
		}
		into.phase(longest);
		return readings;
	}

	/** How long a branch started at `spawned` waited before its process began at `began`: the pool's lease, never below nothing. */
	public static function waitedMs(spawned: Float, began: Float): Float {
		return Math.max(0, began - spawned);
	}

	/**
	 * Why the branch whose process ended as `ran` left no report, at most `WHY_WIDTH` characters. How the process failed comes
	 * first, and its tail is kept (a cut for silence names the row it stood in there, after any wrapper's long path); a process
	 * that failed no way says its first error line, head first.
	 */
	public static function reasonOf(ran: Result): String {
		final failure: String = ran.failure;
		if (failure != '') return failure.length > WHY_WIDTH ? '…${failure.substr(failure.length - WHY_WIDTH)}' : failure;
		final first: String = ran.firstError();
		return first.length > WHY_WIDTH ? '${first.substr(0, WHY_WIDTH)}…' : first;
	}

	/** Leave the steps of `summary` and `readings` at `file` for the run `id` that started this branch. */
	public static function leave(file: String, id: String, summary: Summary, readings: Map<String, Int>): Void {
		File.saveContent(file, encode(id, summary.steps(), readings, Date.now().getTime() - js.Node.process.uptime() * MS_PER_SECOND));
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
	public static function encode(id: String, steps: Array<Step>, readings: Map<String, Int>, ?started: Float): String {
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
					note: step.note,
					excerpt: step.excerpt
				};
			}
		];
		final counts: Array<Reading> = [for (name => value in readings) { name: name, value: value }];
		return BranchReportJsonWriter.write({
			run: id,
			started: started,
			steps: rows,
			readings: counts
		}, JsonFormat.instance.defaultWriteOptions);
	}

	/** The steps and readings of the branch report `text`, as `encode` wrote them. */
	public static function decode(text: String): BranchReport {
		final parsed: BranchReportJson = BranchReportJsonParser.parse(text);
		return {
			run: parsed.run ?? '',
			started: parsed.started,
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
						note: row.note,
						excerpt: row.excerpt ?? []
					}
			],
			readings: [for (reading in parsed.readings) reading.name => reading.value]
		};
	}

	/** What `budget` leaves beside the `held` threads, at least one; null without a budget. */
	public static function share(budget: Null<Int>, held: Int): Null<Int> {
		return budget == null ? null : Std.int(Math.max(1, budget - held));
	}

	/**
	 * `command` of each of `branches` as `mode` runs it. Under `Own` each branch takes a lease of its own: the threads
	 * `demand` names for its rows (none at 0), and the one branch it answers null for, the heavy one, from `Lease.HEAVY_MIN`
	 * up to what the budget leaves beside the others (`share`). The light ones queue a priority step ahead of the
	 * heavy one (`Lease.ahead`): on a busy pool the heavy one waits for its whole share with every free thread closed
	 * behind it, and its own siblings must not wait behind it. A branch's threads go back to the pool as it ends. Under
	 * `Held` and `Unpooled` the command is as it was: the caller splits a held lease with `share` and `light`.
	 */
	public static function leased(
		mode: LeaseMode, branches: Array<Array<String>>, demand: Array<String> -> Null<Int>, command: Array<String> -> Command,
		label: String
	): Array<String> -> Command {
		return switch mode {
			case Own(_, budget):
				final rest: Int = share(budget, light(branches, demand)) ?? 1;
				final ahead: Int = Lease.ahead();
				rows -> {
					final threads: Null<Int> = demand(rows);
					final ask: Null<Ask> = if (threads == null)
						{ min: Std.int(Math.min(Lease.HEAVY_MIN, rest)), max: rest }
					else if (threads > 0)
						{ min: threads, max: threads, priority: ahead }
					else
						null;
					Lease.take(mode, command(rows), ask, '$label ${rows.join(',')}');
				};
			case Held(_), Unpooled: command;
		};
	}

	/** The threads every branch of `branches` but the heavy one holds, as `demand` names them. */
	public static function light(branches: Array<Array<String>>, demand: Array<String> -> Null<Int>): Int {
		var held: Int = 0;
		for (rows in branches) held += demand(rows) ?? 0;
		return held;
	}

}

/** What a branch leaves for the run that started it: its steps, and the counts it read. */
typedef BranchReport = {
	/** The run whose branch left it; empty in a report that names none. */
	var run: String;

	/** When the branch process began, in epoch milliseconds; null in a report that names none. */
	var started: Null<Float>;

	var steps: Array<Step>;
	var readings: Map<String, Int>;
}

package devkit;

import anyparse.grammar.json.JsonFormat;
import devkit.Lease.Ask;
import devkit.Lease.LeaseMode;
import devkit.Summary;
import sys.FileSystem;
import sys.io.File;

using StringTools;
using Lambda;

/** What a branch leaves for the run that started it: its steps, and the counts it read. */
typedef BranchReport = {

	/** The run whose branch left it; empty in a report that names none. */
	var run: String;

	/** When the branch process began, in epoch milliseconds; null in a report that names none. */
	var started: Null<Float>;
	var steps: Array<Step>;
	var readings: Map<String, Int>;

}

/**
 * The steps of a tool's run split into branches that run at once, each a process of the tool: a branch records its steps
 * in a `Summary` of its own and leaves them, with any counts it read, as a report file (`leave`); `run` starts every
 * branch, waits for all of them and adds their steps to the caller's table in table order. A step whose branch ended
 * without reporting it is `NotRun`, and so is one whose report names another run: a branch an earlier run left behind
 * may still write under the same name.
 */
@:nullSafety(Strict)
final class Branches {

	/** The time(1) whose `-l` writes the resource usage of the whole process tree it waited for. */
	public static final TIME: String = '/usr/bin/time';

	/** How long the reason of a step whose branch left no report may grow. */
	private static inline final WHY_WIDTH: Int = 100;

	/** Milliseconds in a second. */
	private static inline final MS_PER_SECOND: Float = 1000;

	/** The bound of a run id's random part. */
	private static inline final NONCE_BOUND: Int = 0x7fffffff;

	/** The file `metered` has time(1) write a branch's usage into, beside the branch's report. */
	public static inline function usageFile(report: String): String {
		return '$report.time';
	}

	/**
	 * Run every branch of `branches` as the process `command` makes of its steps, which leaves its report for the run `id`
	 * at `report(steps)`; add the steps to `into` in `order` and answer the counts the branches read.
	 */
	public static function run(
		id: String, branches: Array<Array<String>>, order: Array<String>, command: Array<String> -> Command,
		report: Array<String> -> String, into: Summary
	): Map<String, Int> {
		for (names in branches)
			for (stale in [report(names), usageFile(report(names))])
				if (FileSystem.exists(stale)) FileSystem.deleteFile(stale);
		final spawned: Float = Date.now().getTime();
		final runs: Array<Result> = Pool.of(branches.length).map(branches, command);
		final readings: Map<String, Int> = [];
		final steps: Map<String, Step> = [];
		final waits: Map<String, Float> = [];
		final cpus: Map<String, Float> = [];
		var longest: Float = 0;
		for (i => names in branches) {
			final file: String = report(names);
			final ran: Result = runs[i];
			File.saveContent('$file.log', ran.out + ran.err + ran.failure);
			final left: Null<BranchReport> = reportOf(file, id);
			final began: Null<Float> = left?.started;
			if (began != null) {
				final waited: Float = waitedMs(spawned, began);
				waits[names[0]] = waited;
				longest = Math.max(longest, waited);
			}
			final used: Null<Float> = cpuOf(file);
			if (used != null) cpus[names[0]] = used;
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
			if (step == null) continue;
			final waited: Null<Float> = waits[name];
			if (waited != null) step.wait = waited;
			final used: Null<Float> = cpus[name];
			if (used != null) step.cpu = used;
			into.addStep(step);
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
					excerpt: step.excerpt,
					wait: step.wait,
					cpu: step.cpu,
					threads: step.threads
				};
			}
		];
		final counts: Array<Reading> = [ for (name => value in readings) { name: name, value: value } ];
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
			steps: parsed.steps.map(stepOf),
			readings: [ for (reading in parsed.readings) reading.name => reading.value ]
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
	 * behind it, and its own siblings must not wait behind it. A branch's threads go back to the pool as it ends. `cores` names
	 * the cpus each process of a light branch runs on (`Ask.cores`, one without it), and the heavy share is what is left beside
	 * the cpus the light ones lease. Under `Held` and `Unpooled` the command is as it was: the caller splits a held lease with
	 * `share` and `light`.
	 */
	public static function leased(
		mode: LeaseMode, branches: Array<Array<String>>, demand: Array<String> -> Null<Int>, command: Array<String> -> Command,
		label: String, ?history: LeaseHistory, ?cores: Array<String> -> Int
	): Array<String> -> Command {
		return switch mode {
			case Own(_, budget):
				final coresOf: Array<String> -> Int = cores ?? (_ -> 1);
				final leasedDemand: Array<String> -> Null<Int> = rows -> {
					final threads: Null<Int> = demand(rows);
					return threads == null ? null : threads * coresOf(rows);
				};
				final rest: Int = perHeavy(budget, branches, leasedDemand) ?? 1;
				final ahead: Int = Lease.ahead();
				rows -> {
					final threads: Null<Int> = demand(rows);
					final ask: Null<Ask> = if (threads == null)
						heavyAsk(Std.int(Math.min(Lease.HEAVY_MIN, rest)), rest, history, timingKey(label, rows))
					else if (threads > 0)
						{
							min: threads,
							max: threads,
							priority: ahead,
							cores: coresOf(rows)
						}
					else
						null;
					Lease.take(mode, command(rows), ask, '$label ${rows.join(',')}');
				};
			case Held(_), Unpooled: command;
		};
	}

	/** The identity of the branch running `rows` under `label` in the timing history: the label of its lease, run ids dropped. */
	public static function timingKey(label: String, rows: Array<String>): String {
		return LeaseHistory.keyOf('$label ${rows.join(',')}');
	}

	/**
	 * The flexible ask of the heavy branch, `min` to `max` threads, with the seconds `history` has for `key` on each size when
	 * it has them for every one.
	 */
	public static function heavyAsk(min: Int, max: Int, history: Null<LeaseHistory>, key: String): Ask {
		final ask: Ask = { min: min, max: max };
		final seconds: Null<Map<Int, Int>> = history?.seconds(key, min, max);
		if (seconds != null) ask.estSeconds = seconds;
		return ask;
	}

	/**
	 * What a branch the pool leased `threads` threads leaves in `history` as it ends, which took as long as this process has
	 * lived: its time on that many threads, unless a step of it did not end fit (a failed run's time says nothing).
	 */
	public static function record(history: LeaseHistory, label: String, rows: Array<String>, threads: Null<Int>, summary: Summary): Void {
		if (threads == null || summary.unfit().length > 0) return;
		history.recordLived(timingKey(label, rows), threads);
	}

	/** The threads every branch of `branches` but the heavy one holds, as `demand` names them. */
	public static function light(branches: Array<Array<String>>, demand: Array<String> -> Null<Int>): Int {
		var held: Int = 0;
		for (rows in branches) held += demand(rows) ?? 0;
		return held;
	}

	/**
	 * What `budget` leaves beside the light branches, split among the heavy ones (those `demand` answers null for) and at
	 * least one each; null without a budget. With one heavy branch it is `share`.
	 */
	public static function perHeavy(budget: Null<Int>, branches: Array<Array<String>>, demand: Array<String> -> Null<Int>): Null<Int> {
		final rest: Null<Int> = share(budget, light(branches, demand));
		if (rest == null) return null;
		final heavy: Int = branches.count(rows -> demand(rows) == null);
		return Std.int(Math.max(1, Math.floor(rest / Math.max(1, heavy))));
	}

	/**
	 * The branch `command` under time(1), which leaves the cpu its whole process tree used in `usageFile(report)` for `run` to
	 * put on the branch's first step: the rows of a branch run in one process, so the reading is the branch's, not a row's.
	 * Applied before a lease prefix, it measures the held window; only macOS's time(1) has `-l`, so elsewhere the command
	 * runs unmetered and its steps carry no cpu.
	 */
	public static function metered(command: Command, report: String): Command {
		return Sys.systemName() == 'Mac' && FileSystem.exists(TIME) ? command.under([TIME, '-l', '-o', usageFile(report)]) : command;
	}

	/** The user plus system cpu seconds of a time(1) report; null when it holds none, as a time killed with its branch leaves. */
	public static function cpuSeconds(text: String): Null<Float> {
		final reading: EReg = ~/([0-9]+[.,][0-9]+) +user +([0-9]+[.,][0-9]+) +sys/;
		return reading.match(text) ? seconds(reading.matched(1)) + seconds(reading.matched(2)) : null;
	}

	/** The step a report row records; a reading the row has none of stays absent on the step, as on a step nothing measured. */
	private static function stepOf(row: StepRecord): Step {
		final step: Step = {
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
		};
		final wait: Null<Float> = row.wait;
		final cpu: Null<Float> = row.cpu;
		final threads: Null<Int> = row.threads;
		if (wait != null) step.wait = wait;
		if (cpu != null) step.cpu = cpu;
		if (threads != null) step.threads = threads;
		return step;
	}

	/** The cpu seconds the time(1) of the branch reporting at `report` left; null when it left none. */
	private static function cpuOf(report: String): Null<Float> {
		final file: String = usageFile(report);
		return FileSystem.exists(file) ? cpuSeconds(File.getContent(file)) : null;
	}

	/** A decimal of time(1)'s report, whose mark may be a comma. */
	private static function seconds(decimal: String): Float {
		return Std.parseFloat(decimal.replace(',', '.'));
	}

}

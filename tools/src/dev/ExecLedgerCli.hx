package dev;

import devkit.Args;
import devkit.ExecLedger;
import devkit.Table;
import haxe.io.Path;

using StringTools;

/** A branch total rows are added to one at a time. */
private abstract Accrual(LedgerTotal) {

	private static inline final MS_PER_MINUTE: Float = 60000;

	public inline function new(total: LedgerTotal) {
		this = total;
	}

	public function push(row: LedgerRow): Void {
		this.rows++;
		this.wallMs += row.wallMs;
		this.waitMs += row.waitMs ?? 0;
		final threads: Null<Int> = row.threads;
		if (threads != null) this.threadMinutes += threads * row.wallMs / MS_PER_MINUTE;
		final cpu: Null<Float> = row.cpuS;
		if (cpu != null) this.cpuS = (this.cpuS ?? 0) + cpu;
		final metered: Bool = this.cpuS != null;
		this.meteredMs = metered ? this.wallMs : 0;
		this.unmetered = metered ? 0 : 1;
	}

}

/** The summed rows of one branch of a phase, or of the whole phase (branch `ExecLedgerCli.TOTAL`). */
typedef LedgerTotal = {

	var phase: String;
	var branch: String;
	var rows: Int;
	var wallMs: Float;
	var waitMs: Float;

	/** The cpu seconds its metered branches used, or null when none was metered. */
	var cpuS: Null<Float>;

	/** The wall time of its metered branches, the time its cpu was spent in. */
	var meteredMs: Float;

	/** Threads held times wall time, in minutes. */
	var threadMinutes: Float;

	/** How many of its branches no cpu reading reached. */
	var unmetered: Int;

}

/**
 * `dev exec-ledger` — the one answer to "what did the rows of the lands cost, summed": the `ExecLedger` file under the
 * blast cache, summed per phase and branch into wall, lease wait, cpu, cores used (cpu seconds over wall seconds),
 * thread-minutes held and cpu-minutes used. A branch's cpu is the whole branch's, so cores are read per branch, never per
 * row; a branch no row of which carries cpu is unmetered, never counted as zero.
 */
@:nullSafety(Strict)
final class ExecLedgerCli {

	public static inline final USAGE: String =
		'usage: dev exec-ledger [--since <YYYY-MM-DD[ HH:MM[:SS]][Z]>] [--until <same>] [--file <ledger.tsv>]';

	/** The branch column of a phase's total line. */
	public static final TOTAL: String = '(total)';

	private static inline final MS_PER_SECOND: Float = 1000;
	private static inline final MS_PER_MINUTE: Float = 60000;
	private static inline final SECONDS_PER_MINUTE: Float = 60;
	private static inline final HUNDREDTHS: Float = 100;

	/** The text of an unmetered reading. */
	private static final NONE: String = '-';

	public static inline function main(argv: Array<String>): Int {
		return run(argv, Sys.println);
	}

	/** `main` with the printed lines handed to `print`: the options are read here, so a test drives them on a literal argv. */
	public static function run(argv: Array<String>, print: String -> Void): Int {
		final args: Args = new Args(argv);
		final since: Null<String> = args.option('--since');
		final until: Null<String> = args.option('--until');
		final file: String = args.option('--file') ?? Path.join([Land.cacheDir(Sys.getEnv), ExecLedger.FILE]);
		args.done();
		final from: Null<Float> = since == null ? null : sinceStart(since);
		final end: Null<Float> = until == null ? null : sinceStart(until);
		final rows: Array<LedgerRow> = before(new ExecLedger(file).rows(), end);
		print(render(summarize(rows, from)));
		print('');
		print(LeaseReadout.render(LeaseReadout.read(rows, from)));
		return 0;
	}

	/** The rows of `rows` recorded before `end` (all when null); a row with no time is kept, as `summarize` leaves it to `--since`. */
	public static function before(rows: Array<LedgerRow>, end: Null<Float>): Array<LedgerRow> {
		return rows.filter(row -> end == null || (row.at ?? end) < end);
	}

	/**
	 * The moment `text` names, in milliseconds since the epoch: `YYYY-MM-DD` (the day's start), with an optional time
	 * `HH:MM[:SS]` after a space or `T`. Local time, or UTC when it ends in `Z`.
	 */
	public static function sinceStart(text: String): Float {
		final utc: Bool = text.endsWith('Z');
		final trimmed: String = utc ? text.substr(0, text.length - 1) : text;
		final clean: String = trimmed.replace('T', ' ');
		final stamp: String = clean.split(' ').length == 2 && clean.split(':').length == 2 ? '$clean:00' : clean;
		final date: Null<Date> = try Date.fromString(stamp) catch (_: haxe.Exception) null;
		if (date == null || Math.isNaN(date.getTime())) throw new UsageError('--since/--until: not a date: $text');
		return date.getTime() - (utc ? date.getTimezoneOffset() * MS_PER_MINUTE : 0);
	}

	/**
	 * The totals of `rows` recorded since `from` (every row when null; a row with no time is then left out), one per phase
	 * and branch in first-seen order, each phase closed by its total line. Each run of a branch is metered on its own, so a
	 * run no cpu reached stays unmetered beside a run of the same branch that was measured. The battery's `span` line is listed on its
	 * own; the phase total takes only its thread-minutes (the lease held for the whole battery), since it covers the branches' rows.
	 */
	public static function summarize(rows: Array<LedgerRow>, from: Null<Float>): Array<LedgerTotal> {
		final runs: Map<String, LedgerTotal> = [];
		final order: Array<LedgerTotal> = [];
		for (row in rows) {
			final at: Null<Float> = row.at;
			if (from != null && (at == null || at < from)) continue;
			runOf(runs, order, row).push(row);
		}
		final phases: Array<String> = [];
		final groups: Map<String, Array<LedgerTotal>> = [];
		for (run in order) fold(totalOf(groups, phases, run.phase, run.branch), run);
		final out: Array<LedgerTotal> = [];
		for (phase in phases) {
			final sum: LedgerTotal = empty(phase, TOTAL);
			for (total in groups[phase] ?? []) {
				out.push(total);
				if (isEnvelope(total))
					sum.threadMinutes += total.threadMinutes;
				else
					fold(sum, total);
			}
			out.push(sum);
		}
		return out;
	}

	/** Cores `total` used: its cpu seconds over the wall seconds of its metered branches, or null when none was metered. */
	public static function cores(total: LedgerTotal): Null<Float> {
		final cpu: Null<Float> = total.cpuS;
		return cpu == null || total.meteredMs <= 0 ? null : cpu / (total.meteredMs / MS_PER_SECOND);
	}

	public static function render(totals: Array<LedgerTotal>): String {
		final cells: Array<Array<String>> = [
			for (total in totals) {
				final cpu: Null<Float> = total.cpuS;
				final used: Null<Float> = cores(total);
				[
					total.phase,
					total.branch,
					'${total.rows}',
					decimal(total.wallMs / MS_PER_SECOND),
					decimal(total.waitMs / MS_PER_SECOND),
					cpu == null ? NONE : decimal(cpu),
					used == null ? NONE : decimal(used),
					decimal(total.threadMinutes),
					cpu == null ? NONE : decimal(cpu / SECONDS_PER_MINUTE),
					'${total.unmetered}'
				];
			}
		];
		return Table.render([
			'phase',
			'branch',
			'rows',
			'wall s',
			'wait s',
			'cpu s',
			'cores',
			'thread-min',
			'cpu-min',
			'unmetered'
		], cells);
	}

	/** Whether `total` is the battery's span, the row that covers the rest of its phase. */
	private static inline function isEnvelope(total: LedgerTotal): Bool {
		return total.phase == ExecLedger.BATTERY_ROW && total.branch == ExecLedger.SPAN_ROW;
	}

	/** The run of a branch `row` adds to: its branch (or, when it names none, itself) recorded at the same time. */
	private static function runOf(runs: Map<String, LedgerTotal>, order: Array<LedgerTotal>, row: LedgerRow): Accrual {
		final branch: String = LeaseReadout.branchOf(row);
		final key: String = '${row.phase}\t$branch\t${row.at ?? -1}';
		final seen: Null<LedgerTotal> = runs[key];
		if (seen != null) return new Accrual(seen);
		final run: LedgerTotal = empty(row.phase, branch);
		run.unmetered = 1;
		runs[key] = run;
		order.push(run);
		return new Accrual(run);
	}

	/** The total of branch `branch` in `phase`, made empty the first time either is seen. */
	private static function totalOf(
		groups: Map<String, Array<LedgerTotal>>, phases: Array<String>, phase: String, branch: String
	): LedgerTotal {
		var list: Null<Array<LedgerTotal>> = groups[phase];
		if (list == null) {
			list = [];
			groups[phase] = list;
			phases.push(phase);
		}
		for (seen in list) if (seen.branch == branch) return seen;
		final total: LedgerTotal = empty(phase, branch);
		list.push(total);
		return total;
	}

	/** Adds `part` to `into`: its cpu and the wall it was spent over only when `part` was metered, its unmetered runs always. */
	private static function fold(into: LedgerTotal, part: LedgerTotal): Void {
		into.rows += part.rows;
		into.wallMs += part.wallMs;
		into.waitMs += part.waitMs;
		into.threadMinutes += part.threadMinutes;
		into.meteredMs += part.meteredMs;
		into.unmetered += part.unmetered;
		final cpu: Null<Float> = part.cpuS;
		if (cpu != null) into.cpuS = (into.cpuS ?? 0) + cpu;
	}

	private static function empty(phase: String, branch: String): LedgerTotal {
		return {
			phase: phase,
			branch: branch,
			rows: 0,
			wallMs: 0,
			waitMs: 0,
			cpuS: null,
			meteredMs: 0,
			threadMinutes: 0,
			unmetered: 0
		};
	}

	private static function decimal(value: Float): String {
		return '${Math.round(value * HUNDREDTHS) / HUNDREDTHS}';
	}

}

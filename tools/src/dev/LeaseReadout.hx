package dev;

import devkit.ExecLedger;
import devkit.Table;

/** What one branch of one run held and used. */
typedef LeaseRun = {

	var phase: String;
	var branch: String;

	/** The wall time of the branch's rows that held a lease, in milliseconds. */
	var leasedMs: Float;

	/** Threads held times wall time over those rows, in milliseconds. */
	var threadMs: Float;

	/** The cpu seconds the branch used. */
	var cpuS: Float;

}

/** The metered runs of one branch of a phase, or of every branch (branch `LeaseReadout.ALL`). */
typedef LeaseBranch = {

	var phase: String;
	var branch: String;
	var runs: Int;

	/** The sum over its runs of mean threads held. */
	var held: Float;

	/** The sum over its runs of cores used. */
	var used: Float;

	/** The sum over its runs of abs(held - used). */
	var gap: Float;

	/** Thread-minutes held above what was used, and used above what was held. */
	var idle: Float;
	var over: Float;

	/** Thread-minutes held and cpu-minutes used. */
	var heldMin: Float;
	var cpuMin: Float;

}

/**
 * The one answer to "per branch of a run, how many threads were held and how many cores used": a run is one branch recorded
 * at one time; held is threads times wall over the wall of its leased rows, used is its cpu over that same wall, and only a run
 * with a lease and cpu above zero is read. Gate rows are regrouped by the real branches of `SliceGate.GATE_BRANCHES`, so a
 * ledger written before the rows were filed that way reads the same. The battery's `span` row and the battery runs that shared
 * one lease between all branches (their `span` carries no cpu, or its own lease) are left out. A branch that holds no lease in
 * the ledger (the gate's `infra4`, which leases per lint in the pool log) is counted unread, never as zero.
 */
@:nullSafety(Strict)
final class LeaseReadout {

	/** The branch column of the line over every branch. */
	public static final ALL: String = '(all)';

	/** The branch column of the line closing a phase's branches: the runs of every branch of that phase. */
	public static final PHASE: String = '(phase)';

	private static inline final MS_PER_SECOND: Float = 1000;
	private static inline final MS_PER_MINUTE: Float = 60000;
	private static inline final SECONDS_PER_MINUTE: Float = 60;
	private static inline final HUNDREDTHS: Float = 100;
	private static inline final PERCENT: Float = 100;

	/** A span row this close to a battery row (in milliseconds) was written by the same battery. */
	private static inline final SPAN_WINDOW_MS: Float = 1000;

	private static final GATE_PHASE: String = 'gate';

	/** Mean abs(held - used) of `line`, or 0 when it read no run. */
	public static inline function meanGap(line: LeaseBranch): Float {
		return line.runs == 0 ? 0 : line.gap / line.runs;
	}

	/** The share of held thread-minutes that was idle or over, in percent. */
	public static inline function mismatch(line: LeaseBranch): Float {
		return line.heldMin <= 0 ? 0 : PERCENT * (line.idle + line.over) / line.heldMin;
	}

	/** The branch a ledger `row` belongs to: for a gate row the real branch of its step, else the branch it names, else itself. */
	public static function branchOf(row: LedgerRow): String {
		return row.phase == GATE_PHASE ? ExecLedger.branchIn(row.row, SliceGate.GATE_BRANCHES) : row.branch ?? row.row;
	}

	/** The metered runs of `rows` recorded since `from` (all when null), as per-branch lines and a closing line over all of them. */
	public static function read(rows: Array<LedgerRow>, from: Null<Float>): Array<LeaseBranch> {
		final kept: Array<LedgerRow> = rows.filter(row -> {
			final at: Null<Float> = row.at;
			return from == null || (at != null && at >= from);
		});
		final spans: Array<LedgerRow> = kept.filter(isSpan);
		final runs: Map<String, LeaseRun> = [];
		final order: Array<LeaseRun> = [];
		for (row in kept) if (!isSpan(row) && !sharedLease(row, spans)) accrue(runs, order, row);
		final phases: Array<String> = [];
		final branches: Map<String, Array<LeaseBranch>> = [];
		final totals: Map<String, LeaseBranch> = [];
		final all: LeaseBranch = empty('', ALL);
		for (run in order) {
			if (run.leasedMs <= 0 || run.cpuS <= 0) continue;
			var lines: Null<Array<LeaseBranch>> = branches[run.phase];
			if (lines == null) {
				lines = [];
				branches[run.phase] = lines;
				totals[run.phase] = empty(run.phase, PHASE);
				phases.push(run.phase);
			}
			var line: Null<LeaseBranch> = null;
			for (seen in lines) if (seen.branch == run.branch) line = seen;
			if (line == null) {
				line = empty(run.phase, run.branch);
				lines.push(line);
			}
			add(line, run);
			add(totals[run.phase] ?? all, run);
			add(all, run);
		}
		final out: Array<LeaseBranch> = [];
		for (phase in phases) {
			for (line in branches[phase] ?? []) out.push(line);
			final total: Null<LeaseBranch> = totals[phase];
			if (total != null) out.push(total);
		}
		out.push(all);
		return out;
	}

	public static function render(lines: Array<LeaseBranch>): String {
		final cells: Array<Array<String>> = lines.map(line -> [
			line.phase,
			line.branch,
			'${line.runs}',
			decimal(line.runs == 0 ? 0 : line.held / line.runs),
			decimal(line.runs == 0 ? 0 : line.used / line.runs),
			decimal(meanGap(line)),
			decimal(line.idle),
			decimal(line.over),
			decimal(line.heldMin),
			decimal(line.cpuMin),
			'${Math.round(mismatch(line))}%'
		]);
		return Table.render([
			'phase',
			'branch',
			'runs',
			'held',
			'used',
			'M',
			'idle',
			'over',
			'thread-min',
			'cpu-min',
			'S'
		], cells);
	}

	private static function isSpan(row: LedgerRow): Bool {
		return row.phase == ExecLedger.BATTERY_ROW && row.row == ExecLedger.SPAN_ROW;
	}

	/** Whether `row` is a battery row whose battery ran its branches under one lease: the span beside it has no cpu reading. */
	private static function sharedLease(row: LedgerRow, spans: Array<LedgerRow>): Bool {
		final at: Null<Float> = row.at;
		if (row.phase != ExecLedger.BATTERY_ROW || at == null) return false;
		for (span in spans) {
			final spanAt: Null<Float> = span.at;
			if (spanAt != null && Math.abs(spanAt - at) < SPAN_WINDOW_MS) return span.cpuS == null;
		}
		return false;
	}

	private static function accrue(runs: Map<String, LeaseRun>, order: Array<LeaseRun>, row: LedgerRow): Void {
		final branch: String = branchOf(row);
		final key: String = '${row.phase}\t$branch\t${row.at ?? -1}';
		var run: Null<LeaseRun> = runs[key];
		if (run == null) {
			run = {
				phase: row.phase,
				branch: branch,
				leasedMs: 0,
				threadMs: 0,
				cpuS: 0
			};
			runs[key] = run;
			order.push(run);
		}
		final threads: Null<Int> = row.threads;
		if (threads != null) {
			run.leasedMs += row.wallMs;
			run.threadMs += threads * row.wallMs;
		}
		run.cpuS += row.cpuS ?? 0;
	}

	private static function add(line: LeaseBranch, run: LeaseRun): Void {
		final held: Float = run.threadMs / run.leasedMs;
		final used: Float = run.cpuS / (run.leasedMs / MS_PER_SECOND);
		final minutes: Float = run.leasedMs / MS_PER_MINUTE;
		line.runs++;
		line.held += held;
		line.used += used;
		line.gap += Math.abs(held - used);
		line.idle += Math.max(0, held - used) * minutes;
		line.over += Math.max(0, used - held) * minutes;
		line.heldMin += run.threadMs / MS_PER_MINUTE;
		line.cpuMin += run.cpuS / SECONDS_PER_MINUTE;
	}

	private static function empty(phase: String, branch: String): LeaseBranch {
		return {
			phase: phase,
			branch: branch,
			runs: 0,
			held: 0,
			used: 0,
			gap: 0,
			idle: 0,
			over: 0,
			heldMin: 0,
			cpuMin: 0
		};
	}

	private static function decimal(value: Float): String {
		return '${Math.round(value * HUNDREDTHS) / HUNDREDTHS}';
	}

}

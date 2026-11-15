package devkit;

using StringTools;

import devkit.Summary.Step;

/**
 * The one answer to "what did each row of a tool run cost, wall and lease wait and cpu and threads, across runs": the
 * finished rows of a run, recorded as one line `row TAB phase TAB wall_ms TAB wait_ms TAB cpu_s TAB threads` in a file
 * under the blast cache (a worktree's own logs die with its slice). A reading a row has none of is an empty field, and a
 * line an older tool wrote with fewer fields reads back with those absent. The file is advisory and bounded: appends are
 * single lines, and a compaction racing an append may lose that line.
 */
@:nullSafety(Strict)
final class ExecLedger {

	/** The most lines the file keeps; past it a record compacts the file. */
	public static inline final MAX_LINES: Int = 2000;

	/** The file's name under the cache directory. */
	public static final FILE: String = 'exec-ledger.tsv';

	/** The fields a line must have to name a row: its row, phase and wall time. */
	private static inline final MIN_FIELDS: Int = 3;

	private static inline final WAIT_FIELD: Int = 3;
	private static inline final CPU_FIELD: Int = 4;
	private static inline final THREADS_FIELD: Int = 5;
	private static inline final BRANCH_FIELD: Int = 6;
	private static inline final AT_FIELD: Int = 7;

	/** A cpu reading is kept to a thousandth of a second. */
	private static inline final MILLIS: Float = 1000;

	private final _log: BoundedLog;

	public function new(file: String) {
		_log = new BoundedLog(file);
	}

	/** One more finished row; a row with no name or no wall time is no reading and is not recorded. */
	public function record(entry: LedgerRow): Void {
		if (entry.row == '' || !(entry.wallMs >= 0)) return;
		_log.append(encode(entry), MAX_LINES, lines -> lines.slice(-MAX_LINES));
	}

	/** Every row the file holds, oldest first; a line that names no row is skipped. */
	public function rows(): Array<LedgerRow> {
		final read: Array<LedgerRow> = [];
		for (line in _log.lines()) {
			final entry: Null<LedgerRow> = decode(line);
			if (entry != null) read.push(entry);
		}
		return read;
	}

	/** `entry` as one line, its absent readings empty and no tab or newline left in its names. */
	public static function encode(entry: LedgerRow): String {
		final wait: Null<Float> = entry.waitMs;
		final cpu: Null<Float> = entry.cpuS;
		final threads: Null<Int> = entry.threads;
		final branch: Null<String> = entry.branch;
		final at: Null<Float> = entry.at;
		return [
			clean(entry.row),
			clean(entry.phase),
			'${Math.round(entry.wallMs)}',
			wait == null ? '' : '${Math.round(wait)}',
			cpu == null ? '' : '${Math.round(cpu * MILLIS) / MILLIS}',
			threads == null ? '' : '$threads',
			branch == null ? '' : clean(branch),
			at == null ? '' : '${Math.round(at)}'
		].join('\t');
	}

	/** The row `line` records, or null when it has no row name or no wall time. */
	public static function decode(line: String): Null<LedgerRow> {
		final fields: Array<String> = line.split('\t');
		if (fields.length < MIN_FIELDS || fields[0] == '') return null;
		final wall: Float = Std.parseFloat(fields[2]);
		final row: Null<LedgerRow> = Math.isNaN(wall) ? null : {
			row: fields[0],
			phase: fields[1],
			wallMs: wall,
			waitMs: number(fields, WAIT_FIELD),
			cpuS: number(fields, CPU_FIELD),
			threads: whole(fields, THREADS_FIELD)
		};
		// the newer fields are left out when absent, so a line an older tool wrote reads back as the row it recorded
		if (row != null) {
			if (BRANCH_FIELD < fields.length && fields[BRANCH_FIELD] != '') row.branch = fields[BRANCH_FIELD];
			final at: Null<Float> = number(fields, AT_FIELD);
			if (at != null) row.at = at;
		}
		return row;
	}

	/**
	 * The rows of a run's `steps` in `phase`, recorded at `at`: a branch starts at a step carrying its lease wait or cpu,
	 * which only a branch's first step carries, or at a step that held no lease; every later step names that first step.
	 */
	public static function ofSteps(phase: String, steps: Array<Step>, at: Float): Array<LedgerRow> {
		final out: Array<LedgerRow> = [];
		var first: String = '';
		for (step in steps) {
			final wait: Null<Float> = step.wait;
			final cpu: Null<Float> = step.cpu;
			final threads: Null<Int> = step.threads;
			if (wait != null || cpu != null || threads == null) first = step.name;
			final row: LedgerRow = {
				row: step.name,
				phase: phase,
				wallMs: step.ms,
				at: at
			};
			if (threads != null) row.threads = threads;
			if (wait != null) row.waitMs = wait;
			if (cpu != null) row.cpuS = cpu;
			if (first != step.name) row.branch = first;
			out.push(row);
		}
		return out;
	}

	/** The reading in field `at`, or null when the line has no such field or it is empty or no number. */
	private static function number(fields: Array<String>, at: Int): Null<Float> {
		final value: Float = at < fields.length ? Std.parseFloat(fields[at]) : Math.NaN;
		return Math.isNaN(value) ? null : value;
	}

	private static function whole(fields: Array<String>, at: Int): Null<Int> {
		final value: Null<Float> = number(fields, at);
		return value == null ? null : Std.int(value);
	}

	private static function clean(text: String): String {
		return text.replace('\t', ' ').replace('\n', ' ').replace('\r', ' ');
	}

}

/** One finished row of a run: what it was, in which phase, and what it cost. */
typedef LedgerRow = {

	var row: String;

	/** The stage of the tool run the row belongs to (`gate`, `land`, …); empty when the caller names none. */
	var phase: String;

	/** The row's wall time, in milliseconds. */
	var wallMs: Float;

	/** How long its branch waited for a pool lease, in milliseconds. */
	@:optional
	var waitMs: Float;

	/** The cpu seconds its process used. */
	@:optional
	var cpuS: Float;

	/** The pool threads it held. */
	@:optional
	var threads: Int;

	/** The first row of the branch that ran it, whose cpu and wait are the whole branch's; absent when the row is its own branch. */
	@:optional
	var branch: String;

	/** When the row was recorded, in milliseconds since the epoch; absent on a line an older tool wrote. */
	@:optional
	var at: Float;

}

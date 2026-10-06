package anyparse.core;

import haxe.Exception;
import haxe.Timer;

/**
 * One row of the timings report: a phase name, the wall time spent in it, how often it ran, and when it first started.
 */
typedef PhaseRow = {
	var phase: String;
	var seconds: Float;
	var count: Int;
	var firstAt: Float;
}

/**
 * Wall-clock phase timings of one `apq` process, printed on stderr when `APQ_TIMINGS` is set.
 *
 * A diagnostic, never an input: nothing reads a timing back, so a run's output is the same with the
 * flag on or off. With it off every `measure` is one boolean test and a direct call. Phases nest — a
 * row is INCLUSIVE of the rows measured inside it — and a phase measured many times (one per pass, one
 * per rule) is summed into one row with its count. The rows print in the order the phases first
 * started, which is the order a reader follows the run in.
 *
 * Process-scoped on purpose: a timing has to be taken where the work happens, deep under call chains
 * that carry no run object, and a report that changes no result is the one state that may live there.
 */
@:nullSafety(Strict)
final class PhaseTimings {

	/** Whether this process records timings (`APQ_TIMINGS`). */
	public static final enabled: Bool = EnvFlag.isSet('APQ_TIMINGS');

	/** A process's CPU clock counts microseconds. */
	private static inline final MICROSECONDS: Float = 1e6;

	/** One decimal: a phase is read to the tenth of a second. */
	private static inline final TENTHS: Float = 10;

	private static final rows: Array<PhaseRow> = [];
	private static final byPhase: Map<String, PhaseRow> = [];
	private static final origin: Float = Timer.stamp();

	/** `body`'s result, its wall time added to `phase` when timings are on. */
	public static function measure<T>(phase: String, body: () -> T): T {
		if (!enabled) return body();
		final started: Float = Timer.stamp();
		final result: T = try body() catch (exception: Exception) {
			add(phase, Timer.stamp() - started, started);
			throw exception;
		};
		add(phase, Timer.stamp() - started, started);
		return result;
	}

	/** `measure` for a `body` that returns nothing. */
	public static function time(phase: String, body: () -> Void): Void {
		if (!enabled) {
			body();
			return;
		}
		final started: Float = Timer.stamp();
		try body() catch (exception: Exception) {
			add(phase, Timer.stamp() - started, started);
			throw exception;
		}
		add(phase, Timer.stamp() - started, started);
	}

	/** Add `seconds` that began at the `Timer.stamp()` value `startedAt` to `phase`. */
	public static function add(phase: String, seconds: Float, startedAt: Float): Void {
		if (!enabled) return;
		final row: Null<PhaseRow> = byPhase[phase];
		if (row != null) {
			row.seconds += seconds;
			row.count++;
			return;
		}
		final fresh: PhaseRow = {
			phase: phase,
			seconds: seconds,
			count: 1,
			firstAt: startedAt - origin
		};
		rows.push(fresh);
		byPhase[phase] = fresh;
	}

	/** The report, one line per phase in first-start order, written through `write`; nothing when timings are off. */
	public static function report(write: (String) -> Void): Void {
		if (!enabled) return;
		final ordered: Array<PhaseRow> = rows.copy();
		ordered.sort((a, b) -> a.firstAt < b.firstAt ? -1 : a.firstAt > b.firstAt ? 1 : 0);
		write('apq timings: ${seconds(Timer.stamp() - origin)} wall since start${cpuNote()}\n');
		for (row in ordered)
			write(
				'apq timings: ${seconds(row.seconds)} ${row.count > 1 ? 'x${row.count} ' : ''}${row.phase} (first at +${seconds(row.firstAt)})\n'
			);
	}

	/** This process's own CPU time (user + system, its children not included), where the target can tell. */
	private static function cpuNote(): String {
		#if nodejs
		final used: { user: Float, system: Float } = js.Syntax.code('process.cpuUsage()');
		return ', ${seconds((used.user + used.system) / MICROSECONDS)} cpu in this process';
		#else
		return '';
		#end
	}

	/** `value` seconds to one decimal, followed by `s`. */
	private static function seconds(value: Float): String {
		return '${Math.round(value * TENTHS) / TENTHS}s';
	}

}

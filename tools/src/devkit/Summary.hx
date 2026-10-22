package devkit;

import haxe.Exception;
import haxe.Timer;

using Lambda;
using StringTools;

/**
 * The steps of a tool's run and how each ended, kept in run order — the table a tool prints last and the one verdict it
 * exits with. A step has four outcomes, never two: a step that could not run (`NotRun`, and every step that threw)
 * fails the verdict on its own, so it can never read as a pass; only `Skipped` — a step the tool decided does not apply —
 * is benign.
 */
@:nullSafety(Strict)
final class Summary {

	/** Milliseconds in a second. */
	private static inline final MS_PER_SECOND: Float = 1000;

	/** The table's seconds are given to a tenth. */
	private static inline final TENTHS_PER_SECOND: Int = 10;

	/** The width of the table's outcome column: its longest label, `not run`. */
	private static inline final OUTCOME_WIDTH: Int = 7;

	/** The width of the table's seconds column. */
	private static inline final SECONDS_WIDTH: Int = 7;

	private final _steps: Array<Step> = [];

	public function new() {}

	/** Record `name` as ended with `outcome` after `ms` milliseconds. */
	public function add(name: String, outcome: Outcome, ms: Float = 0): Void {
		_steps.push({ name: name, outcome: outcome, ms: ms });
	}

	/** Run `step` as the step `name`, timed; a step that throws is recorded `NotRun` with the exception's message. */
	public function time(name: String, step: () -> Outcome): Outcome {
		final started: Float = Timer.stamp();
		final outcome: Outcome = try step() catch (exception: Exception) NotRun(exception.message);
		add(name, outcome, (Timer.stamp() - started) * MS_PER_SECOND);
		return outcome;
	}

	/** Whether every step passed or was skipped. */
	public function passed(): Bool {
		for (step in _steps) switch step.outcome {
			case Passed, Skipped(_):
			case Failed(_), NotRun(_):
				return false;
		}
		return true;
	}

	/** One aligned row per step: name, outcome, seconds, and the reason when there is one. */
	public function table(): String {
		final width: Int = _steps.fold((step: Step, w: Int) -> step.name.length > w ? step.name.length : w, 0);
		final rows: Array<String> = [
			for (step in _steps) {
				final why: String = switch step.outcome {
					case Passed: '';
					case Failed(why), NotRun(why), Skipped(why): '  $why';
				};
				'${step.name.rpad(' ', width)}  ${label(step.outcome).rpad(' ', OUTCOME_WIDTH)}  ${seconds(step.ms).lpad(' ', SECONDS_WIDTH)}$why';
			}
		];
		return rows.join('\n');
	}

	private static function label(outcome: Outcome): String {
		return switch outcome {
			case Passed: 'passed';
			case Failed(_): 'FAILED';
			case NotRun(_): 'not run';
			case Skipped(_): 'skipped';
		};
	}

	/** `ms` as seconds with one decimal and an `s`. */
	private static function seconds(ms: Float): String {
		final tenths: Int = Math.round(ms * TENTHS_PER_SECOND / MS_PER_SECOND);
		return '${Std.int(tenths / TENTHS_PER_SECOND)}.${tenths % TENTHS_PER_SECOND}s';
	}

}

/** How one step of a `Summary` ended. */
enum Outcome {
	Passed;
	Failed(why: String);

	/** The step could not produce a verdict at all — it fails the run like `Failed`. */
	NotRun(why: String);

	/** The tool decided the step does not apply. */
	Skipped(why: String);
}

/** One recorded step of a `Summary`. */
typedef Step = {
	var name: String;
	var outcome: Outcome;
	var ms: Float;
}

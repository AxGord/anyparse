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

	/** The shortest lease wait, in milliseconds, a table shows: a shorter one is process start, not the pool. */
	private static inline final WAIT_SHOWN_MS: Float = 1000;

	private final _steps: Array<Step> = [];

	/** How long the branch that ran each step waited for its pool lease before the step, in milliseconds, by step name. */
	private final _waits: Map<String, Float> = [];

	/** The longest wait of each fan-out, in milliseconds: fan-outs run one after another, so these add up to at most the wall. */
	private final _phases: Array<Float> = [];

	/** The note the step `time` is running has set so far (`detail`). */
	private var _note: String = '';

	/** The lines the step `time` is running has set so far (`excerpt`). */
	private var _excerpt: Array<String> = [];

	public function new() {}

	/** Inside a step `time` runs: the reading its row shows when the step passes (a count, a gate line). */
	public inline function detail(note: String): Void {
		_note = note;
	}

	/**
	 * Inside a step `time` runs: the lines that decide it, shown under the table when the step fails or did not run
	 * (`Excerpt.cut` bounds them).
	 */
	public inline function excerpt(lines: Array<String>): Void {
		_excerpt = lines;
	}

	/**
	 * Record the longest lease wait among the branches one fan-out started together. Branches wait concurrently, so a
	 * fan-out costs the run its longest wait, never their sum.
	 */
	public inline function phase(ms: Float): Void {
		_phases.push(ms);
	}

	/** The steps recorded so far, in run order. */
	public inline function steps(): Array<Step> {
		return _steps.copy();
	}

	/** Record `name` as ended with `outcome` after `ms` milliseconds, with `note` shown beside a pass and `excerpt` under a failure. */
	public function add(name: String, outcome: Outcome, ms: Float = 0, note: String = '', ?excerpt: Array<String>): Void {
		_steps.push({
			name: name,
			outcome: outcome,
			ms: ms,
			note: note,
			excerpt: excerpt ?? []
		});
	}

	/** Run `step` as the step `name`, timed; a step that throws is recorded `NotRun` with the exception's message. */
	public function time(name: String, step: () -> Outcome): Outcome {
		final started: Float = Timer.stamp();
		_note = '';
		_excerpt = [];
		final outcome: Outcome = try step() catch (exception: Exception) NotRun(exception.message);
		add(name, outcome, (Timer.stamp() - started) * MS_PER_SECOND, _note, _excerpt);
		return outcome;
	}

	/** Record that the branch whose first step is `name` waited `ms` milliseconds for its pool lease. */
	public function wait(name: String, ms: Float): Void {
		_waits[name] = ms;
	}

	/** The seconds the branches waited for their leases in all, as the verdict line shows them; empty when none waited. */
	public function waitedTotal(): String {
		var sum: Float = 0;
		for (ms in _phases) if (ms >= WAIT_SHOWN_MS) sum += ms;
		return sum == 0 ? '' : 'waited ${Math.round(sum / MS_PER_SECOND)}s';
	}

	/** The verdict line's tail: the total in parentheses after a space, or empty when no fan-out waited. */
	public function waitedSuffix(): String {
		final total: String = waitedTotal();
		return total == '' ? '' : ' ($total)';
	}

	/** Whether every step passed or was skipped. */
	public function passed(): Bool {
		return unfit().length == 0;
	}

	/** The names of the steps that failed or could not run, in run order. */
	public function unfit(): Array<String> {
		return [for (step in _steps) if (!step.outcome.match(Passed | Skipped(_))) step.name];
	}

	/** One aligned row per step: name, outcome, seconds, and the reason when there is one. */
	public function table(): String {
		final width: Int = _steps.fold((step: Step, w: Int) -> step.name.length > w ? step.name.length : w, 0);
		final rows: Array<String> = [
			for (step in _steps) {
				final why: String = switch step.outcome {
					case Passed: step.note == '' ? '' : '  ${step.note}';
					case Failed(why), NotRun(why), Skipped(why): '  $why';
				};
				final waited: Float = _waits[step.name] ?? 0;
				final wait: String = waited >= WAIT_SHOWN_MS ? '  waited ${Math.round(waited / MS_PER_SECOND)}s' : '';
				'${step.name.rpad(' ', width)}  ${label(step.outcome).rpad(' ', OUTCOME_WIDTH)}  ${seconds(step.ms).lpad(' ', SECONDS_WIDTH)}$why$wait';
			}
		];
		return rows.join('\n');
	}

	/**
	 * The excerpt of every step that failed or did not run, each under its name and cut to the bound; empty when no
	 * such step has one.
	 */
	public function excerpts(): String {
		final blocks: Array<String> = [];
		for (step in _steps) {
			final failing: Bool = switch step.outcome {
				case Failed(_), NotRun(_): true;
				case Passed, Skipped(_): false;
			};
			if (!failing || step.excerpt.length == 0) continue;
			blocks.push('${step.name}:\n' + Excerpt.cut(step.excerpt).map(line -> '  $line').join('\n'));
		}
		return blocks.join('\n');
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

	/** The reading a passed step shows; empty when it has none. */
	var note: String;

	/** The lines that decide a step that failed or did not run; empty when it set none. */
	var excerpt: Array<String>;

}

package devkit;

import anyparse.core.PoolLease;
import haxe.io.Path;
import sys.FileSystem;

/**
 * Where the threads of a run's heavy processes come from, and the command that takes them. Under `Own` each heavy process
 * takes a lease of its own from the machine-wide pool through `wf-run` and gives it back the moment it ends, so a long
 * light tail never keeps a heavy phase's threads. A run that already holds a lease never asks the pool again: a waiter
 * queued ahead of it for the threads it holds would wait for ever (hold and wait).
 */
@:nullSafety(Strict)
final class Lease {

	/** The fewest threads a flexible lease (a run's heaviest branch) takes. */
	public static inline final HEAVY_MIN: Int = 2;

	/** How long a flexible lease waits for its whole share before it takes what fits, in seconds. */
	public static inline final WAIT_FULL_SECONDS: Int = 30;

	/** The pool's command under the workflow plugin's root, which a workflow exec names in `WF_PLUGIN_ROOT`. */
	private static inline final WF_RUN: String = 'scripts/wf-run';

	/** What the pool's status may take before the run gives up on the pool. */
	private static inline final STATUS_TIMEOUT_MS: Int = 30 * 1000;

	/** The budget on the first line of `wf-run --status`. */
	private static final BUDGET_LINE: EReg = ~/^pool .*: budget (\d+),/m;

	/** A priority as the pool reads it: an integer, nothing around it. */
	private static final INTEGER: EReg = ~/^-?\d+$/;

	/** The mode of this process's environment: its caller's lease (`WF_THREADS`), else the pool a workflow exec reaches. */
	public static function ofEnvironment(): LeaseMode {
		return modeOf(PoolLease.threads(), Sys.getEnv('WF_PLUGIN_ROOT'), budgetThrough);
	}

	/**
	 * The mode for a `held` lease of the caller and the workflow plugin's `root`: `Held` under a lease, `Own` when the root's
	 * `wf-run` is there and `probe` reads the pool's budget through it, else `Unpooled`.
	 */
	public static function modeOf(held: Null<Int>, root: Null<String>, probe: String -> Null<Int>): LeaseMode {
		if (held != null) return Held(held);
		if (root == null || root == '') return Unpooled;
		final wfRun: String = Path.join([root, WF_RUN]);
		if (!FileSystem.exists(wfRun)) return Unpooled;
		final budget: Null<Int> = probe(wfRun);
		return budget == null || budget < 1 ? Unpooled : Own(wfRun, budget);
	}

	/** The budget the pool's `status` text names, or null when it names none. */
	public static function budgetOf(status: String): Null<Int> {
		return BUDGET_LINE.match(status) ? Std.parseInt(BUDGET_LINE.matched(1)) : null;
	}

	/**
	 * `command` under a lease of its own of `ask` threads, labelled `label` in the pool, when `mode` is `Own` and there is an
	 * `ask`; else `command` as it is. A pool `wf-run` cannot use runs the command unleased on the fewest threads it asked
	 * (`--fail-open`): the pool never fails a run. `WF_THREADS` of the command is what the lease granted.
	 */
	public static function take(mode: LeaseMode, command: Command, ask: Null<Ask>, label: String): Command {
		return switch [mode, ask] {
			case [Own(wfRun, _), ask] if (ask != null):
				final flexible: Bool = ask.min < ask.max;
				final prefix: Array<String> = [
					wfRun,
					'--fail-open',
					'--threads',
					flexible ? '${ask.min}-${ask.max}' : '${ask.max}'
				];
				if (flexible) prefix.push('--wait-full=$WAIT_FULL_SECONDS');
				if (ask.priority != null) prefix.push('--priority=${ask.priority}');
				command.under(prefix.concat(['--label', label, '--']));
			case _: command;
		};
	}

	/**
	 * The pool priority one step ahead of the caller's own (`WF_PRIORITY`, 0 when it names none): a lease asked at it queues
	 * before every lease the caller's run asks at its own priority, whenever either arrived.
	 */
	public static function ahead(): Int {
		final own: String = Sys.getEnv('WF_PRIORITY') ?? '';
		return (INTEGER.match(own) ? Std.parseInt(own) ?? 0 : 0) + 1;
	}

	/** The pool's budget as `wf-run --status` names it, or null when the status does not come. */
	private static function budgetThrough(wfRun: String): Null<Int> {
		final status: Result = Command.of([wfRun, '--status']).timeout(STATUS_TIMEOUT_MS).run();
		return status.ok ? budgetOf(status.out) : null;
	}

}

/** Where the threads of a run's heavy processes come from. */
enum LeaseMode {

	/** No pool: every process runs as it would without one. */
	Unpooled;

	/** The run holds a lease of `threads` from its caller: its processes share them, and none asks the pool again. */
	Held(threads: Int);

	/** The run holds none: each heavy process takes its own lease of the pool's `budget` threads through `wfRun`. */
	Own(wfRun: String, budget: Int);

}

/** The threads one lease asks for: exactly `max`, or flexibly from `min` up to `max`. */
typedef Ask = {
	var min: Int;
	var max: Int;

	/**
	 * The pool priority the lease queues at, or null for the caller's own (`WF_PRIORITY`). A priority given here is no longer
	 * re-ranked with the caller's level.
	 */
	@:optional var priority: Int;
}

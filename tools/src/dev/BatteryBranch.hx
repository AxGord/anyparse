package dev;

import devkit.Args;
import devkit.Branches;
import devkit.Command;
import devkit.Summary;
import haxe.io.Path;

/**
 * The one answer to "which process runs one branch of a battery": `dev battery --rows` over the run's plan, under time(1)
 * inside whatever lease prefix wraps it, so the cpu its report carries is the held window's.
 */
@:nullSafety(Strict)
final class BatteryBranch {

	/** What a branch may run before it is killed: a wedged run, not a slow one. */
	private static inline final TIMEOUT_MS: Int = 3 * 60 * 60 * 1000;

	/** The ledger file `dev battery --ledger <file>` names for its rows, or null for the blast cache's. */
	public static inline function ledgerOf(args: Args): Null<String> {
		return args.option('--ledger');
	}

	/** The branch of `plan` running `rows` through the `dev.js` copy `self`, its plan read from `planFile`, metered into `report`. */
	public static function command(plan: BatteryPlan, self: String, planFile: String, rows: Array<String>, report: String): Command {
		return Branches.metered(
			Command.of(['node', self, 'battery', '--rows', rows.join(','), '--plan', planFile])
				.at(plan.repo)
				.env(GateTree.ENGINE_VAR, Path.join([plan.repo, 'bin/apq.js']))
				.timeout(TIMEOUT_MS),
			report
		);
	}

	/**
	 * Each step of `steps` that is one of the branch's `rows` carries the threads `held` it ran under; none when it held no lease.
	 */
	public static function carryThreads(steps: Array<Step>, rows: Array<String>, held: Null<Int>): Void {
		if (held != null) for (step in steps) if (rows.contains(step.name)) step.threads = held;
	}

	/** The threads a branch's steps carry: its own lease when each branch takes one, none when the branches share their caller's. */
	public static function branchHeld(ownLease: Bool, lease: Null<Int>): Null<Int> {
		return ownLease ? lease : null;
	}

	/**
	 * The threads the battery's span row carries: the lease its caller holds for the whole run, once; none when each branch took its own.
	 */
	public static function spanHeld(ownLease: Bool, lease: Null<Int>): Null<Int> {
		return ownLease ? null : lease;
	}

}

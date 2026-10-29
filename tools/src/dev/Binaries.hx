package dev;

import devkit.Cmd.cmd;
import devkit.Lease;
import devkit.Pool;
import devkit.Result;
import devkit.Summary.Outcome;
import sys.io.File;

using Lambda;

/** The three binaries a tree's gates and merges run on — `apq.js`, `test.js` and `dev.js` — built at once. */
@:nullSafety(Strict)
final class Binaries {

	/** The build files of the three, from the tree's root. */
	public static final HXMLS: Array<String> = ['bin/apq-js.hxml', 'test-js.hxml', 'tools/dev.hxml'];

	/** Build the three binaries of `tree`, every transcript written to `log`; a failure quotes the first one's error. */
	public static function compile(tree: String, log: String): Outcome {
		return compileWith(tree, log, [], Unpooled);
	}

	/**
	 * `compile`, with each build file of `typechecks` typechecked beside the three (`--no-output`: it writes nothing) — the gate
	 * of a file no binary reaches —, each compile on a thread `mode` leases for it alone.
	 */
	public static function compileWith(tree: String, log: String, typechecks: Array<String>, mode: LeaseMode): Outcome {
		final builds: Array<Array<String>> = [for (hxml in HXMLS) [hxml]].concat([for (hxml in typechecks) [hxml, '--no-output']]);
		final runs: Array<Result> = Pool.of(builds.length)
			.map(builds, words -> Lease.take(mode, cmd('haxe $words').at(tree), { min: 1, max: 1 }, 'haxe ${words.join(' ')}'));
		File.saveContent(log, [for (run in runs) run.out + run.err].join('\n'));
		final failed: Null<Result> = runs.find(run -> !run.ok);
		return failed == null ? Passed : Failed('${failed.command}: ${failed.firstError()}');
	}

}

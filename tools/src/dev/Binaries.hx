package dev;

import devkit.Cmd.cmd;
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
		final runs: Array<Result> = Pool.of(HXMLS.length).map(HXMLS, hxml -> cmd('haxe $hxml').at(tree));
		File.saveContent(log, [for (run in runs) run.out + run.err].join('\n'));
		final failed: Null<Result> = runs.find(run -> !run.ok);
		return failed == null ? Passed : Failed('${failed.command}: ${failed.firstError()}');
	}

}

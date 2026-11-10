package dev;

import devkit.Cmd.cmd;
import devkit.Result;
import devkit.Summary.Outcome;

using Lambda;
using StringTools;

/**
 * The one answer to "what row do the typer's probe projects make in a gate's table": the slice gate and the battery both run
 * `dev typer-conformance probes` through it, so a slice that moves the typer fails its own gate and not the land.
 */
@:nullSafety(Strict)
final class TyperProbesRow {

	/** The lines of a failed run shown when it names no `DIFFERENT` probe. */
	private static inline final TAIL_LINES: Int = 20;

	/** The probe corpus; a change to it moves the row whatever the engine did. */
	private static final PROBES: String = 'tools/typer-facts/';

	/** The harness that scores the probes, compiled into `bin/dev.js`. */
	private static final HARNESS: String = 'tools/src/dev/TyperConformance.hx';

	/**
	 * `dev typer-conformance probes` run in `repo`; on a failure `show` gets the `DIFFERENT` lines, or the tail of the run when it
	 * names none.
	 */
	public static function outcome(repo: String, show: String -> Void): Outcome {
		final run: Result = cmd('node bin/dev.js typer-conformance probes').at(repo).run();
		if (run.ok) return Passed;
		final lines: Array<String> = '${run.out}${run.err}'.split('\n');
		final different: Array<String> = lines.filter(l -> l.startsWith('DIFFERENT'));
		show((different.length > 0 ? different : lines.slice(-TAIL_LINES)).join('\n'));
		return Failed('the typer answered a probe otherwise than the compiler (the DIFFERENT lines or the run tail: see this row output)');
	}

	/**
	 * Whether a slice that touched `touched` can move the probes' answers: the engine they ask, the probe corpus or the harness
	 * moved. Any other change leaves every probe reading as the baseline's.
	 */
	public static function reached(touched: Array<String>): Bool {
		return touched.exists(file -> GateTree.isEngineInput(file) || file.startsWith(PROBES) || file == HARNESS);
	}

}

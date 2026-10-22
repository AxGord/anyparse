package dev;

import devkit.Args;
import devkit.Cmd.cmd;
import devkit.Command;
import sys.FileSystem;

using StringTools;

/**
 * `dev bench-ab [--config <hxformat.json>] <mode> <target> <rounds> <reps> <label>:<binary>...` — the parse/writer
 * harness (`parse-prof`) run by several builds, interleaved round by round, the MEDIAN per arm the result. A `.js` arm is
 * a `bin/dev.js` build, run as `node <binary> parse-prof …`; any other arm is executed as it is, so a native build of the
 * harness (`tools/bench-hxcpp.hxml`) is just another arm. Arms run one at a time, because parallel arms share caches and
 * turbo, and a single before/after pair cannot tell a win from machine drift (`docs/testing.md` § "Layer 5").
 */
@:nullSafety(Strict)
final class BenchAb {

	public static inline final USAGE: String =
		'usage: dev bench-ab [--config <hxformat.json>] <mode> <target> <rounds> <reps> <label>:<binary>...';

	/** The positionals before the first arm: mode, target, rounds, reps. */
	private static inline final RUN_ARGUMENTS: Int = 4;

	/** The width the arm label is padded to in the medians table. */
	private static inline final LABEL_WIDTH: Int = 16;

	/** The width of each number in the medians table. */
	private static inline final NUMBER_WIDTH: Int = 9;

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final configOption: Null<String> = args.option('--config');
		final given: Array<String> = args.rest(['<mode>', '<target>', '<rounds>', '<reps>', '<label>:<binary>']);
		final config: String = if (configOption == null)
			'hxformat.json'
		else {
			if (!FileSystem.exists(configOption)) throw new UsageError('config $configOption not found');
			FileSystem.fullPath(configOption);
		};
		final mode: String = given[0];
		final target: String = given[1];
		final rounds: Null<Int> = Std.parseInt(given[2]);
		final reps: String = given[3];
		if (rounds == null) throw new UsageError('<rounds> is a count, not ${given[2]}');
		final arms: Array<{ label: String, binary: String }> = given.slice(RUN_ARGUMENTS).map(arm);
		final root: String = cmd('git rev-parse --show-toplevel').text().trim();
		final nice: Int = js.Syntax.code("require('os').getPriority()");
		final clock: String = DateTools.format(Date.now(), '%H:%M:%S');
		Sys.println('# config=$config mode=$mode target=$target rounds=$rounds reps=$reps nice=$nice $clock');
		final times: Map<String, Array<Float>> = [for (arm in arms) arm.label => []];
		for (round in 1...rounds + 1) for (arm in arms) {
			final run: Command = arm.binary.endsWith('.js')
				? cmd('node ${arm.binary} parse-prof $mode $target $reps $config')
				: cmd('${arm.binary} $mode $target $reps $config');
			final lines: Array<String> = run.at(root).run().lines();
			final line: String = lines.length == 0 ? '' : lines[lines.length - 1];
			final ms: Null<String> = msPerRep(line);
			Sys.println('round=$round arm=${arm.label} ms=${ms ?? line} | $line');
			if (ms != null) times[arm.label]?.push(Std.parseFloat(ms));
		}
		Sys.println('\n# medians (ms per rep)');
		for (arm in arms) Sys.println(medianRow(arm.label, times[arm.label] ?? []));
		return 0;
	}

	/** The `msPerRep=` reading of a harness's summary line, as written; null when it carries none. */
	public static function msPerRep(line: String): Null<String> {
		final reading: EReg = ~/ msPerRep=([0-9.]+) /;
		return reading.match(line) ? reading.matched(1) : null;
	}

	/** `<label> median=… n=… min=… max=…`: the median is the LOWER middle reading of an even count. */
	public static function medianRow(label: String, readings: Array<Float>): String {
		final sorted: Array<Float> = readings.copy();
		sorted.sort(Reflect.compare);
		final n: Int = sorted.length;
		final pick: Int -> String = i -> fixed(n == 0 ? 0 : sorted[i]).lpad(' ', NUMBER_WIDTH);
		return '${label.rpad(' ', LABEL_WIDTH)} median=${pick(Std.int((n + 1) / 2) - 1)}  n=$n  min=${pick(0)}  max=${pick(n - 1)}';
	}

	/** `value` to one decimal place, as `printf %.1f` writes it. */
	private static inline function fixed(value: Float): String {
		return js.Syntax.code('{0}.toFixed(1)', value);
	}

	/** One `<label>:<binary>` arm; an arm with no label is labelled by its binary. */
	private static function arm(spec: String): { label: String, binary: String } {
		final colon: Int = spec.indexOf(':');
		return colon < 0 ? { label: spec, binary: spec } : { label: spec.substr(0, colon), binary: spec.substr(colon + 1) };
	}

}

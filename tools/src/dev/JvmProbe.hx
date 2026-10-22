package dev;

import devkit.Args;
import devkit.Cmd.cmd;
import devkit.Result;

/**
 * `dev jvm-portability [--no-build] [<path>...]` — the static-target probe (`JvmPortability`) built for `--jvm` from
 * `tools/jvm-portability.hxml` and run under `java`, its report passed through. The probe stays a JVM build of its own:
 * that compile IS the check, so it never joins `bin/dev.js`. Exits 0 only when the core compiled and the probe's gate
 * line holds (`wrote == files`, `threw == 0`) — docs/testing.md § "The core stays target-independent".
 */
@:nullSafety(Strict)
final class JvmProbe {

	public static inline final USAGE: String = 'usage: dev jvm-portability [--no-build] [--repo <tree>] [<path>...]';

	/** The group of the gate line's `threw=` count. */
	private static inline final THREW_GROUP: Int = 3;

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final repo: String = Repo.resolve(args.option('--repo'));
		final noBuild: Bool = args.flag('--no-build');
		final paths: Array<String> = args.rest([]);
		if (!noBuild) {
			final build: Result = cmd('haxe tools/jvm-portability.hxml').at(repo).run();
			if (!build.ok) {
				Sys.stderr().writeString('${build.out}${build.err}dev jvm-portability: the core no longer compiles for --jvm\n');
				return 1;
			}
		}
		final run: Result = cmd('java -jar bin/jvm-portability.jar $paths').at(repo).run();
		Sys.print(run.out);
		Sys.stderr().writeString(run.err);
		final why: Null<String> = refusal(run);
		if (why == null) return 0;
		Sys.stderr().writeString('dev jvm-portability: $why\n');
		return 1;
	}

	/** Why the probe run `run` fails its gate, or null when it holds. */
	public static function refusal(run: Result): Null<String> {
		if (!run.ok) return run.failure != '' ? run.failure : 'the probe exited ${run.status}';
		final gate: EReg = ~/^gate: files=(\d+) wrote=(\d+) threw=(\d+)/m;
		if (!gate.match(run.out)) return 'the probe printed no gate line';
		if (gate.matched(THREW_GROUP) != '0')
			return 'the portability probe threw (a parse failure or a comment loss, never a formatting difference)';
		if (gate.matched(1) != gate.matched(2)) return 'the probe wrote ${gate.matched(2)} of ${gate.matched(1)} file(s)';
		return null;
	}

}

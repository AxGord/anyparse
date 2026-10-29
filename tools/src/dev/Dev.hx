package dev;

import devkit.Args.UsageError;
import haxe.Exception;

using Lambda;

/**
 * `node bin/dev.js <subcommand> [args]` — the developer CLI over `devkit` (build: `haxe tools/dev.hxml`). Every
 * subcommand answers its exit status; a command line it cannot read exits 2 with its usage, and so does a tool it
 * needed that failed to run (`CommandFailed`).
 */
@:nullSafety(Strict)
final class Dev {

	/** Each subcommand with its entry and its usage line, in the order `--help` lists them. */
	private static final COMMANDS: Array<Subcommand> = [
		{ name: 'scrub-guard', main: ScrubGuard.main, usage: ScrubGuard.USAGE },
		{ name: 'clone-census', main: CloneCensus.main, usage: CloneCensus.USAGE },
		{ name: 'worker-build', main: WorkerBuild.main, usage: WorkerBuild.USAGE },
		{ name: 'shard', main: Shard.main, usage: Shard.USAGE },
		{ name: 'mutation-arm', main: MutationArm.main, usage: MutationArm.USAGE },
		{ name: 'mutation-check', main: MutationCheck.main, usage: MutationCheck.USAGE },
		{ name: 'slice-gate', main: SliceGate.main, usage: SliceGate.USAGE },
		{ name: 'land', main: Land.main, usage: Land.USAGE },
		{ name: 'merge-arms', main: MergeArms.main, usage: MergeArms.USAGE },
		{ name: 'decision', main: Decision.main, usage: Decision.USAGE },
		{ name: 'tmp-lifecycle', main: Tmp.main, usage: Tmp.USAGE },
		{ name: 'fixture-cache', main: FixtureCacheCli.main, usage: FixtureCacheCli.USAGE },
		{ name: 'jvm-portability', main: JvmProbe.main, usage: JvmProbe.USAGE },
		{ name: 'typer-conformance', main: TyperConformance.main, usage: TyperConformance.USAGE },
		{ name: 'edge-diff', main: EdgeDiff.main, usage: EdgeDiff.USAGE },
		{ name: 'parse-prof', main: ParseProf.run, usage: ParseProf.USAGE },
		{ name: 'prof-top', main: ProfTop.main, usage: ProfTop.USAGE },
		{ name: 'bench-ab', main: BenchAb.main, usage: BenchAb.USAGE },
		{ name: 'lint-warn', main: LintWarn.main, usage: LintWarn.USAGE },
		{ name: 'gate-probe', main: HookProbe.gate, usage: HookProbe.GATE_USAGE },
		{ name: 'lint-warn-probe', main: HookProbe.lintWarn, usage: HookProbe.LINT_WARN_USAGE }
	];

	public static function main(): Void {
		final proc: js.node.Process = js.Node.process;
		// a reader that closed its end of the pipe early is not a tool failure: exit quietly instead of a raw stack
		function epipeQuiet(err: js.lib.Error): Void {
			if (Reflect.field(err, 'code') == 'EPIPE')
				proc.exit(0)
			else
				throw err;
		}
		proc.stdout.on('error', epipeQuiet);
		proc.stderr.on('error', epipeQuiet);
		// set the status and let node exit by itself: `process.exit` can cut off output still being written to a pipe
		proc.exitCode = run(Sys.args());
	}

	/** Run the subcommand `argv[0]` over the rest of `argv`; answers the exit status. */
	public static function run(argv: Array<String>): Int {
		final name: Null<String> = argv[0];
		if (name == null || name == '--help' || name == '-h') {
			Sys.println(usage());
			return name == null ? 2 : 0;
		}
		final command: Null<Subcommand> = COMMANDS.find(c -> c.name == name);
		if (command == null) {
			Sys.stderr().writeString('dev: unknown subcommand $name\n${usage()}\n');
			return 2;
		}
		final rest: Array<String> = argv.slice(1);
		if (!rest.contains('--help') && !rest.contains('-h')) return try command.main(rest) catch (error: UsageError) {
			Sys.stderr().writeString('dev $name: ${error.message}\n${command.usage}\n');
			2;
		} catch (exception: Exception) {
			// a tool it needed failed to run (`CommandFailed`), or an input it could not read
			Sys.stderr().writeString('dev $name: ${exception.message}\n');
			2;
		};
		Sys.println(command.usage);
		return 0;
	}

	private static function usage(): String {
		return 'usage: node bin/dev.js <subcommand> [args]\n' + [for (c in COMMANDS) '  ${c.usage}'].join('\n');
	}

}

/** One subcommand of `Dev`. */
typedef Subcommand = {
	var name: String;
	var main: Array<String> -> Int;
	var usage: String;
}

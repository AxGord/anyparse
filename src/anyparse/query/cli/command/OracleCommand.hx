package anyparse.query.cli.command;

import anyparse.check.CompilerOracle;
import anyparse.check.LintConfig;
import anyparse.check.OracleCache;
import anyparse.query.cli.CliContext;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq oracle` — typecheck the project once and record the verdict for lint.
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class OracleCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'oracle';
	}

	public function summary(): String {
		return 'Typecheck the project once and record the verdict for lint';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runOracle(args);
	}

	public function usage(): Void {
		printOracleUsage();
	}

	/**
	 * `apq oracle <scope>` — run the compiler oracle ONCE, cold, and record its verdict under
	 * the current content fingerprint, so a following `apq lint` reuses it instead of
	 * typechecking the same tree a second time. It cannot lie: the compiler ALWAYS runs, and
	 * nothing is recorded that was not observed. A tree that moves between the two commands
	 * simply misses the fingerprint and recompiles.
	 *
	 * The scope is there to locate the project's `apqlint.json` exactly as `lint` does; without
	 * a `compilerOracle` key the command is inert and exits 0, again exactly like `lint`.
	 */
	private static function runOracle(args: Array<String>): Int {
		var lang: String = 'haxe';
		final specs: Array<String> = [];
		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					// hxq shim auto-injects --lang haxe; the scope is resolved through the same
					// helper `lint` uses, so accept + consume the value to keep shim invariance.
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '-h', '--help':
					printOracleUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('-')) {
						CliIo.stderr('apq oracle: unknown option "$a"\n');
						printOracleUsage();
						return EXIT_USAGE;
					}
					specs.push(a);
			}
			i++;
		}
		if (specs.length == 0) {
			CliIo.stderr('apq oracle: expected <scope> (one or more file/dir/glob specs)\n');
			printOracleUsage();
			return EXIT_USAGE;
		}
		final paths: Array<String> = CliArgs.resolveInputPaths(lang, specs).paths;
		if (paths.length == 0) {
			CliIo.stderr('apq oracle: ${CliArgs.quotedSpecs(specs)} matched no .hx files\n');
			return EXIT_RUNTIME;
		}
		final config: LintConfig = LintConfig.discover(paths[0]);
		final hxml: Null<String> = config.compilerOracle();
		if (hxml != null) return recordOracleVerdict(hxml, config.compilerOracleDir());
		CliIo.stderr('apq oracle: no compilerOracle configured for ${specs.join(', ')} — nothing to typecheck\n');
		return EXIT_OK;
	}

	/**
	 * The compile-and-record half of `apq oracle`: the fingerprint is taken BEFORE the compile
	 * (it describes the input the compiler is about to read), one COLD typecheck runs — never
	 * the warm server, never the cache — and only an observed verdict is stored. A project that
	 * yields no fingerprint says so, so a silently non-caching setup is visible rather than a
	 * `lint` that mysteriously never speeds up.
	 */
	private static function recordOracleVerdict(hxml: String, dir: Null<String>): Int {
		final fingerprint: Null<String> = OracleCache.fingerprint(hxml, dir);
		final outcome: OracleOutcome = CompilerOracle.typecheck(hxml, dir);
		if (fingerprint != null) OracleCache.store(hxml, dir, fingerprint, outcome);
		final exit: Int = reportOracleRun(outcome);
		if (fingerprint == null) CliIo.stderr('apq oracle: no fingerprint for this project — the verdict was not recorded\n');
		return exit;
	}

	/** One stderr line per `apq oracle` outcome, plus the exit status that goes with it. */
	private static function reportOracleRun(outcome: OracleOutcome): Int {
		switch outcome {
			case Confirmed:
				CliIo.stderr('apq oracle: build typechecks — verdict recorded (lint will not recompile an unchanged tree)\n');
			case Unavailable(reason):
				CliIo.stderr('apq oracle: unavailable — $reason (nothing recorded)\n');
			case Rejected(errors):
				CliIo.stderr('apq oracle: build does NOT typecheck:\n$errors\n');
				return EXIT_RUNTIME;
		}
		return EXIT_OK;
	}

	private static function printOracleUsage(): Void {
		CliIo.sysPrint('Usage: apq oracle <scope>\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Typecheck the project ONCE, cold, and record the verdict under a content\n');
		CliIo.sysPrint('fingerprint of the whole compile input — every hxml in the include chain and\n');
		CliIo.sysPrint('every .hx on the classpath the compiler itself names. A later `apq lint`\n');
		CliIo.sysPrint('re-derives that fingerprint and reuses the verdict only while it still\n');
		CliIo.sysPrint('matches, so an edited tree is recompiled rather than trusted.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('The compiler ALWAYS runs here — there is no flag that records a verdict\n');
		CliIo.sysPrint('nobody observed. The scope only locates the project apqlint.json; without a\n');
		CliIo.sysPrint('`compilerOracle` key the command is inert. Exit 0 when the build typechecks\n');
		CliIo.sysPrint('or the oracle could not run, 1 when it does not typecheck, 2 on usage.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  -h, --help      Show this help\n');
	}

}

package anyparse.query.cli.command;

import anyparse.check.CompilerOracle;
import anyparse.check.ConfigDisagreement;
import anyparse.check.LintConfig;
import anyparse.check.OracleCache;
import anyparse.check.OracleGeneration;
import anyparse.query.cli.CliContext;
import anyparse.query.ExitCode.*;
import haxe.io.Path;

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
		// `lint` over the same scope asks the FIRST path's builds, so those are the verdicts worth recording; a scope
		// whose roots name other builds is told so, in `lint`'s own words, rather than silently judged by the first.
		final configByDir: Map<String, LintConfig> = [];
		function resolveConfig(file: String): LintConfig {
			final dir: String = Path.directory(file);
			final cached: Null<LintConfig> = configByDir[dir];
			if (cached != null) return cached;
			final discovered: LintConfig = LintConfig.discover(file);
			configByDir[dir] = discovered;
			return discovered;
		}
		ConfigDisagreement.warnOracle(resolveConfig, paths);
		final oracles: Array<OracleConfig> = resolveConfig(paths[0]).compilerOracles();
		if (oracles.length > 0) return recordOracleVerdicts(oracles);
		CliIo.stderr('apq oracle: no compilerOracle configured for ${specs.join(', ')} — nothing to typecheck\n');
		return EXIT_OK;
	}

	/**
	 * Every configuration recorded, and a non-zero exit when ANY of them does not typecheck.
	 *
	 * All of them rather than up to the first rejection: the point of the command is to leave a
	 * verdict for each configuration the following `lint` will ask about, and a run that stopped
	 * early would leave the rest to recompile. The compiles overlap (`CompilerOracle.typecheckEach`);
	 * each fingerprint is taken BEFORE them, since it describes the input the compiler is about to
	 * read. A configuration whose `generate` command failed is reported unavailable and records nothing.
	 */
	private static function recordOracleVerdicts(oracles: Array<OracleConfig>): Int {
		final prepared: PreparedOracles = OracleGeneration.prepare(oracles);
		for (note in prepared.notes) CliIo.stderr('apq oracle: compilerOracle $note\n');
		final ready: Array<OracleConfig> = prepared.oracles;
		// one read of each source across every configuration, before the compiles and again after them
		final before: Map<String, String> = [];
		final after: Map<String, String> = [];
		final fingerprints: Array<Null<String>> = [
			for (oracle in ready) oracle.unavailable == null
				? OracleCache.fingerprint(oracle.hxml, oracle.dir, oracle.defines, before)
				: null
		];
		final outcomes: Array<Null<OracleOutcome>> = CompilerOracle.typecheckEach(ready, false);
		var exit: Int = EXIT_OK;
		final answered: Array<OracleOutcome> = [];
		for (i in 0...ready.length) {
			final oracle: OracleConfig = ready[i];
			final outcome: OracleOutcome = outcomes[i] ?? Unavailable('the typecheck was cancelled');
			answered.push(outcome);
			final fingerprint: Null<String> = fingerprints[i];
			final stored: Bool = fingerprint != null
				&& OracleCache.storeIfUnchanged(oracle.hxml, oracle.dir, fingerprint, outcome, oracle.defines, after);
			if (reportOracleRun(oracle, outcome) != EXIT_OK) exit = EXIT_RUNTIME;
			if (fingerprint == null && oracle.unavailable == null)
				CliIo.stderr('apq oracle: no fingerprint for ${LintConfig.describeOracle(oracle)} — the verdict was not recorded\n');
			else if (fingerprint != null && !stored)
				CliIo.stderr(
					'apq oracle: the compile input of ${LintConfig.describeOracle(oracle)} changed during the typecheck — the verdict was not recorded\n'
				);
		}
		CliIo.stderr(verdictSummary(answered));
		// the compiles are done: another run may regenerate these builds now
		OracleGeneration.release(ready);
		return exit;
	}

	/** One stderr line per configuration's `apq oracle` outcome, plus the exit status that goes with it. */
	private static function reportOracleRun(oracle: OracleConfig, outcome: OracleOutcome): Int {
		final named: String = LintConfig.describeOracle(oracle);
		switch outcome {
			case Confirmed:
				CliIo.stderr('apq oracle: $named typechecks — verdict recorded (lint will not recompile an unchanged tree)\n');
			case Unavailable(reason):
				CliIo.stderr('apq oracle: $named unavailable — $reason (nothing recorded)\n');
			case Rejected(errors):
				CliIo.stderr('apq oracle: $named does NOT typecheck:\n$errors\n');
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
		CliIo.sysPrint('or the oracle could not run, 1 when it does not typecheck, 2 on usage. The\n');
		CliIo.sysPrint('last stderr line counts both: `N of M configuration(s) typecheck, R do NOT,\n');
		CliIo.sysPrint('U UNAVAILABLE` — read it, not the status, to know every one was confirmed.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('A configuration with a `generate` command has it run first when its hxml is\n');
		CliIo.sysPrint('stale; the configurations then compile concurrently (APQ_ORACLE_PARALLEL=<n>).\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  -h, --help      Show this help\n');
	}

	/**
	 * The closing line of an `apq oracle` run: how many configurations typecheck, how many do not, and how many could not
	 * be asked. Exit 0 covers both "typechecks" and "could not run", so this line is what tells them apart — a caller
	 * that needs every configuration confirmed reads it (or the per-configuration lines), never the status alone.
	 */
	private static function verdictSummary(outcomes: Array<OracleOutcome>): String {
		final confirmed: Int = outcomes.filter(o -> o.match(Confirmed)).length;
		final rejected: Int = outcomes.filter(o -> o.match(Rejected(_))).length;
		final unavailable: Int = outcomes.length - confirmed - rejected;
		final tail: String = unavailable == 0 ? '' : ', $unavailable UNAVAILABLE (no verdict recorded for them)';
		return 'apq oracle: $confirmed of ${outcomes.length} configuration(s) typecheck, $rejected do NOT$tail\n';
	}

}

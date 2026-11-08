package dev;

import anyparse.check.LintConfig;
import anyparse.check.oracle.OracleCache;
import anyparse.check.oracle.OracleCoverage;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import devkit.Cmd.cmd;
import devkit.Lease;
import devkit.Pool;
import devkit.Result;
import devkit.Summary.Outcome;
import haxe.io.Path;
import sys.io.File;

using Lambda;

/** The three binaries a tree's gates and merges run on — `apq.js`, `test.js` and `dev.js` — built at once. */
@:nullSafety(Strict)
final class Binaries {

	/** The build files of the three, from the tree's root. */
	public static final HXMLS: Array<String> = ['bin/apq-js.hxml', 'test-js.hxml', 'tools/dev.hxml'];

	/** The codegen flag every real build of the tree carries and no typecheck leaf does: what turns a typecheck into the shipped build. */
	public static final CODEGEN: Array<String> = ['-D', 'analyzer-optimize'];

	/**
	 * The typecheck leaf the compiler oracle declares for a build leaf `hxml` (`x.hxml` is `x-check.hxml`): the same flags
	 * without the codegen flag `-D analyzer-optimize`, which only a real build carries.
	 */
	public static function checkOf(hxml: String): String {
		return '${Path.withoutExtension(hxml)}-check.hxml';
	}

	/** Build the three binaries of `tree`, every transcript written to `log`; a failure quotes the first one's error. */
	public static function compile(tree: String, log: String): Outcome {
		return compileWith(tree, log, [], Unpooled);
	}

	/**
	 * `compile`, with each build file of `typechecks` typechecked beside the three (`--no-output`: it writes nothing) — the gate
	 * of a file no binary reaches —, each compile on a thread `mode` leases for it alone.
	 */
	public static function compileWith(tree: String, log: String, typechecks: Array<String>, mode: LeaseMode): Outcome {
		return compileBuilds(tree, log, HXMLS.map(hxml -> [hxml]).concat(typechecks.map(hxml -> [hxml, '--no-output'])), mode);
	}

	/**
	 * Run each of `builds` (a haxe command line) in `tree`, every transcript written to `log`. A build the project declares as a
	 * plain `compilerOracle` configuration runs with `-v`, and its green is kept as that configuration's verdict
	 * (`OracleCache.storeIfUnchanged`), so a lint or a battery over the same content does not compile it again. The
	 * configuration a build leaf stands for may be the leaf itself or its `checkOf` typecheck leaf.
	 */
	public static function compileBuilds(tree: String, log: String, builds: Array<Array<String>>, mode: LeaseMode): Outcome {
		final declared: Array<OracleConfig> = plainOracles(tree);
		final oracles: Array<Null<OracleConfig>> = builds.map(words ->
			declared.find(oracle ->
				[words[0], checkOf(words[0])].exists(hxml -> Path.normalize(oracle.hxml) == Path.normalize(Path.join([tree, hxml])))
			)
		);
		final read: Map<String, String> = [];
		final fingerprints: Array<Null<String>> = oracles.map(
			oracle -> oracle == null ? null : OracleCache.fingerprint(oracle.hxml, oracle.dir, oracle.defines, read)
		);
		final runs: Array<Result> = Pool.of(builds.length).map([for (i in 0...builds.length) i], i -> {
			final words: Array<String> = oracles[i] == null ? builds[i] : ['-v'].concat(builds[i]);
			return Lease.take(mode, cmd('haxe $words').at(tree), { min: 1, max: 1 }, 'haxe ${builds[i].join(' ')}');
		});
		// a -v compile prints a line per parsed file and per macro on stdout: it stays out of the log and of the error a failure quotes
		final quiet: Array<Result> = [for (i => run in runs) oracles[i] == null ? run : run.errorsOnly()];
		File.saveContent(log, quiet.map(run -> run.out + run.err).join('\n'));
		final after: Map<String, String> = [];
		for (i => oracle in oracles) {
			final fingerprint: Null<String> = fingerprints[i];
			if (oracle != null && fingerprint != null && runs[i].ok)
				OracleCache.storeIfUnchanged(
					oracle.hxml, oracle.dir, fingerprint, Confirmed, oracle.defines, after, OracleCoverage.parsedPaths(runs[i].out)
				);
		}
		final failed: Null<Result> = quiet.find(run -> !run.ok);
		return failed == null ? Passed : Failed('${failed.command}: ${failed.firstError()}');
	}

	/**
	 * The `compilerOracle` builds `tree`'s project declares whose verdict is that of `haxe <hxml> --no-output` alone: no
	 * defines, no module list, no generating command — anything else is a different compile than the one a build answers.
	 */
	private static function plainOracles(tree: String): Array<OracleConfig> {
		return [
			for (oracle in LintConfig.discover(Path.join([tree, 'apq.json']))
				.compilerOracles(new HaxeQueryPlugin()))
				if (
					oracle.unavailable == null
					&& oracle.defines.length == 0
					&& (oracle.modules ?? []).length == 0
					&& oracle.generate == null
				)
					oracle
		];
	}

}

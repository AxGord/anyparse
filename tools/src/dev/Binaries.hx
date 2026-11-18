package dev;

import anyparse.check.ConfigNotes;
import anyparse.check.LintConfig;
import anyparse.check.haxe.oracle.OracleCache;
import anyparse.check.haxe.oracle.OracleCoverage;
import anyparse.grammar.haxe.query.HaxeQueryPlugin;
import anyparse.query.FileIdentity;
import devkit.Cmd.cmd;
import devkit.Lease;
import devkit.Pool;
import devkit.Result;
import devkit.Summary.Outcome;
import haxe.io.Path;
import sys.io.File;

using Lambda;

/** The three binaries a tree's gates and merges run on — `apq.js`, `test.js` and `dev.js` — built together. */
@:nullSafety(Strict)
final class Binaries {

	/** The builds that run at once under per-build leases: `test.js` is the longest and the others end inside its wall. */
	public static inline final WIDTH: Int = 2;

	/** The build files of the three, from the tree's root. */
	public static final HXMLS: Array<String> = ['bin/apq-js.hxml', 'test-js.hxml', 'tools/dev.hxml'];

	/** The codegen flag every real build of the tree carries and no typecheck leaf does: what turns a typecheck into the shipped build. */
	public static final CODEGEN: Array<String> = ['-D', 'analyzer-optimize'];

	/** What a build log says for a build line the tree's binaries already are the build of (`BuildStamp`), never run again. */
	public static final CURRENT: String = 'current — the binaries are this content\'s build already, not compiled again';

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
	public static function compileWith(
		tree: String, log: String, typechecks: Array<String>, mode: LeaseMode, ?held: Null<Int> -> Void
	): Outcome {
		return compileBuilds(tree, log, HXMLS.map(hxml -> [hxml]).concat(typechecks.map(hxml -> [hxml, '--no-output'])), mode, held);
	}

	/**
	 * Run each of `builds` (a haxe command line) in `tree`, every transcript written to `log`. A build the project declares as a
	 * plain `compilerOracle` configuration runs with `-v`, and its green is kept as that configuration's verdict
	 * (`OracleCache.storeIfUnchanged`), so a lint or a battery over the same content does not compile it again. The
	 * configuration a build leaf stands for may be the leaf itself or its `checkOf` typecheck leaf. A `reusable` line whose
	 * binaries the tree already holds for its content as it stands (`BuildStamp`) is not run again: a land's build stands for
	 * the battery's over the same candidate; the stamp keys the tree by its real path, so the spelling a caller names it by
	 * (a symlinked temp root) never splits one tree's stamp. `held` is told, before anything runs, the threads the builds that do
	 * run hold (`heldBy`): none when the stamp takes them all.
	 */
	public static function compileBuilds(
		tree: String, log: String, builds: Array<Array<String>>, mode: LeaseMode, ?held: Null<Int> -> Void
	): Outcome {
		final real: String = FileIdentity.realPath(tree);
		final declared: Array<OracleConfig> = plainOracles(tree);
		final oracles: Array<Null<OracleConfig>> = builds.map(words ->
			declared.find(oracle ->
				[words[0], checkOf(words[0])].exists(hxml -> Path.normalize(oracle.hxml) == Path.normalize(Path.join([tree, hxml])))
			)
		);
		final read: Map<String, String> = [];
		final stamp: BuildStamp = BuildStamp.of(real, hxml -> OracleCache.fingerprint(hxml, real, null, read));
		final pending: Array<Int> = [ for (i => words in builds) if (!(reusable(words) && stamp.holds(words))) i ];
		final fingerprints: Array<Null<String>> = oracles.map(
			oracle -> oracle == null ? null : OracleCache.fingerprint(oracle.hxml, oracle.dir, oracle.defines, read)
		);
		if (held != null) held(heldBy(mode, pending.length));
		final runs: Array<Result> = runPending(tree, builds, oracles, pending, mode);
		// a -v compile prints a line per parsed file and per macro on stdout: it stays out of the log and of the error a failure quotes
		final quiet: Array<Result> = [ for (k => run in runs) oracles[pending[k]] == null ? run : run.errorsOnly() ];
		final reused: Array<String> = [
			for (i => words in builds) if (!pending.contains(i)) 'haxe ${words.join(' ')}: $CURRENT'
		];
		File.saveContent(log, reused.concat(quiet.map(run -> run.out + run.err)).join('\n'));
		final after: Map<String, String> = [];
		for (k => run in runs) {
			final oracle: Null<OracleConfig> = oracles[pending[k]];
			final fingerprint: Null<String> = fingerprints[pending[k]];
			if (oracle != null && fingerprint != null && run.ok)
				OracleCache.storeIfUnchanged(
					oracle.hxml, oracle.dir, fingerprint, Confirmed, oracle.defines, after, OracleCoverage.parsedPaths(run.out)
				);
		}
		stamp.record([
			for (i => words in builds) if (reusable(words) && (!pending.contains(i) || runs[pending.indexOf(i)].ok)) words
		]);
		final failed: Null<Result> = quiet.find(run -> !run.ok);
		return failed == null ? Passed : Failed('${failed.command}: ${failed.firstError()}');
	}

	/**
	 * How many of `builds` compiles run at once under `mode`: under their own leases (`Own`) at most `WIDTH`, so the shorter
	 * builds follow one another on the second thread while the longest fills the row's wall; all of them otherwise.
	 */
	public static function width(mode: LeaseMode, builds: Int): Int {
		return switch mode {
			case Own(_, _): builds < WIDTH ? builds : WIDTH;
			case Held(_), Unpooled: builds;
		};
	}

	/**
	 * The pool threads `builds` compiles that run at once hold under `mode`: `width` of them when each leases its own (`Own`),
	 * what the caller's lease holds under `Held`, none unpooled and none when no build runs.
	 */
	public static function heldBy(mode: LeaseMode, builds: Int): Null<Int> {
		if (builds == 0) return null;
		return switch mode {
			case Own(_, _): width(mode, builds);
			case Held(held): held;
			case Unpooled: null;
		};
	}

	/**
	 * The `compilerOracle` builds `tree`'s project declares whose verdict is that of `haxe <hxml> --no-output` alone: no
	 * defines, no module list, no generating command — anything else is a different compile than the one a build answers.
	 */
	private static function plainOracles(tree: String): Array<OracleConfig> {
		return [
			for (oracle in ConfigNotes.into(
				null, notes -> LintConfig.discover(Path.join([tree, 'apq.json']), notes).compilerOracles(new HaxeQueryPlugin(), notes)
			))
				if (
					oracle.unavailable == null
					&& oracle.defines.length == 0
					&& (oracle.modules ?? []).length == 0
					&& oracle.generate == null
				)
					oracle
		];
	}

	/**
	 * Whether a green build line may be taken from `BuildStamp` instead of run: one of `HXMLS` as it stands, whose binary is an
	 * ignored `bin/*.js` the stamp digests, or a typecheck, which writes nothing.
	 */
	private static function reusable(words: Array<String>): Bool {
		return (words.length == 1 && HXMLS.contains(words[0])) || words.contains('--no-output');
	}

	/**
	 * Each build of `pending` (indexes into `builds`), at most `width` at a
	 * time, each on a thread `mode` leases for it alone; an oracle's with `-v`.
	 */
	private static function runPending(
		tree: String, builds: Array<Array<String>>, oracles: Array<Null<OracleConfig>>, pending: Array<Int>, mode: LeaseMode
	): Array<Result> {
		return pending.length == 0
			? []
			: Pool.of(width(mode, pending.length)).map(pending, i -> {
				final words: Array<String> = oracles[i] == null ? builds[i] : ['-v'].concat(builds[i]);
				return Lease.take(mode, cmd('haxe $words').at(tree), { min: 1, max: 1 }, 'haxe ${builds[i].join(' ')}');
			});
	}

}

package anyparse.query.cli;

import anyparse.check.LintConfig;
import anyparse.check.oracle.CompilerOracle;
import anyparse.check.oracle.HaxeSpawn;
import anyparse.check.oracle.OracleCache;
import anyparse.check.oracle.OracleCoverage;
import anyparse.check.oracle.OracleDeclaration;
import anyparse.query.ExitCode;
import anyparse.query.cli.WriteJournal.JournalState;
import haxe.io.Path;

using Lambda;

/** One configured build's answer about the written tree: the build as compiled, its verdict, every file it parsed (canonical). */
typedef BuildAnswer = {
	final oracle: OracleConfig;
	final outcome: Null<OracleOutcome>;
	final parsed: Array<String>;
}

/**
 * The typecheck after a write command — the one answer to "did this write keep every configured build compiling, and
 * which builds can say so": each `compilerOracle` build compiled with `-v` over what the run wrote, and the run's writes
 * put back when a build that typechecked before the write does not after it.
 *
 * Only a build that PARSED a written source vouches for the write (`OracleCoverage`'s compiled set); a written module no
 * build reaches is compiled again by naming it to every build whose class path holds it, and a CREATED one that none of
 * them compiles is put back. A green build is believed as is; only a red one costs a compile of the tree with the write
 * rolled back, and one red either way judges nothing (`CompilerOracle.judging`'s rule). It runs by default only for a run
 * that created or deleted a file, and for any write under `--verify`: a compile of every build costs more than most
 * in-place edits are worth.
 */
@:nullSafety(Strict)
final class WriteVerification {

	/** The flag that tells a write command to skip the check; the dispatcher strips it. */
	public static inline final OPT_OUT: String = '--no-verify';

	/** The flag that asks for the check after an in-place edit; stripped unless the command reads a `--verify` of its own. */
	public static inline final OPT_IN: String = '--verify';

	/** How many builds compile at once when the process holds no pool lease. */
	private static inline final UNLEASED_COMPILES: Int = 2;

	/**
	 * Settle `journal`, the writes of the `op` run that answered `exit`: typechecked when the run created or deleted a file,
	 * or when `forced`. Answers `exit`, or `EXIT_RUNTIME` with every file the run wrote put back when the write broke a build.
	 */
	public static function settle(op: String, journal: WriteJournal, exit: Int, forced: Bool): Int {
		final changed: Array<String> = journal.changed();
		if (changed.length == 0 || !forced && !journal.createdOrDeleted()) return exit;
		final oracles: Array<OracleConfig> = try {
			oraclesOf(changed);
		} catch (exception: Exception) {
			CliIo.stderr('apq $op: unverified — the apqlint.json naming the builds could not be read: ${exception.message}\n');
			return exit;
		}
		if (oracles.length != 0) return try {
			judge(op, journal, oracles, changed, exit);
		} catch (exception: Exception) {
			journal.rollback();
			CliIo.stderr('apq $op: the typecheck after the write threw: ${exception.message} — every file put back\n');
			ExitCode.EXIT_RUNTIME;
		}
		CliIo.stderr('apq $op: unverified — no "compilerOracle" in apqlint.json covers the written files\n');
		return exit;
	}

	/** Every configured build the `apqlint.json` of each of `paths` names, each once. */
	private static function oraclesOf(paths: Array<String>): Array<OracleConfig> {
		final dirs: Array<String> = [];
		for (path in paths) {
			final dir: String = Path.directory(path);
			if (!dirs.contains(dir)) dirs.push(dir);
		}
		final out: Array<OracleConfig> = [];
		final keys: Array<String> = [];
		for (dir in dirs) for (oracle in LintConfig.discover(Path.join([dir, '_'])).compilerOracles()) {
			final key: String = OracleDeclaration.oracleKey(oracle);
			if (keys.contains(key)) continue;
			keys.push(key);
			out.push(oracle);
		}
		return out;
	}

	/** `settle` once the builds are known. */
	private static function judge(op: String, journal: WriteJournal, oracles: Array<OracleConfig>, changed: Array<String>, exit: Int): Int {
		final parallel: Int = HaxeSpawn.unleasedParallelism(UNLEASED_COMPILES);
		final sources: Array<String> = [
			for (path in changed) if (OracleCoverage.isSource(path) && ConfigFinder.fileExists(path)) path
		];
		final after: Array<BuildAnswer> = compile(oracles, parallel);
		for (a in after) switch a.outcome {
			case Unavailable(reason):
				CliIo.stderr('apq $op: ${a.oracle.hxml} could not typecheck the write: $reason\n');
			case _:
		}
		if (putBackIfBroken(op, journal, after, parallel)) return ExitCode.EXIT_RUNTIME;
		final vouching: Array<String> = [
			for (a in after) if (confirmed(a) && (sources.length == 0 || sources.exists(s -> parsedBy(a, s)))) a.oracle.hxml
		];
		// only a build that typechecks the written tree can judge a module named to it
		final judges: Array<OracleConfig> = [for (a in after) if (confirmed(a)) a.oracle];
		final unreached: Array<String> = [for (s in sources) if (!after.exists(a -> parsedBy(a, s))) s];
		if (judges.length > 0 && unreached.length > 0 && !keptUnreached(op, journal, judges, unreached, vouching, parallel))
			return ExitCode.EXIT_RUNTIME;
		final count: Int = vouching.length;
		if (count > 0)
			CliIo.stderr('apq $op: verified by $count configured build${CliIo.plural(count)}\n')
		else if (judges.length == 0)
			CliIo.stderr('apq $op: unverified — no configured build could judge the write\n');
		return exit;
	}

	/** `oracles` compiled with `-v`, `parallel` at a time: each verdict, with what it parsed. */
	private static function compile(oracles: Array<OracleConfig>, parallel: Int): Array<BuildAnswer> {
		final readings: Array<OracleReading> = CompilerOracle.typecheckEachReading(oracles, false, parallel);
		return [
			for (i => oracle in oracles) {
				final base: String = oracle.dir ?? Sys.getCwd();
				{
					oracle: oracle,
					outcome: readings[i].outcome,
					parsed: [for (path in readings[i].parsed ?? []) OracleCoverage.canonical(base, path)]
				};
			}
		];
	}

	/** Each of `oracles` whose explicit class path holds one of `files`, naming those files' modules on its command line. */
	private static function naming(oracles: Array<OracleConfig>, files: Array<String>): Array<OracleConfig> {
		final out: Array<OracleConfig> = [];
		for (oracle in oracles) {
			final roots: Array<String> = OracleCache.classPaths(oracle.hxml, oracle.dir);
			final modules: Array<String> = [];
			for (file in files) {
				final module: Null<String> = OracleCoverage.moduleUnder(roots, file);
				if (module != null) modules.push(module);
			}
			if (modules.length == 0) continue;
			// a copy of every field, so one added to `OracleConfig` later is carried without a line here
			final named: OracleConfig = Reflect.copy(oracle) ?? throw new Exception('a configuration could not be copied');
			named.modules = modules;
			out.push(named);
		}
		return out;
	}

	/** Print the errors of `rejected` (each distinct line once) and say `why` the run's files were put back. */
	private static function putBack(op: String, rejected: Array<BuildAnswer>, why: String): Void {
		printErrors(op, rejected);
		CliIo.stderr('apq $op: $why — every file put back\n');
	}

	/** The compiler's errors of every rejected build of `answers`, each distinct line once, under the builds that gave them. */
	private static function printErrors(op: String, answers: Array<BuildAnswer>): Void {
		final lines: Array<String> = [];
		for (a in answers) switch a.outcome {
			case Rejected(errors):
				for (line in errors.split('\n')) if (line.trim() != '' && !lines.contains(line))
					lines.push(line);
			case _:
		}
		CliIo.stderr('apq $op: ${names(answers)} rejected the write:\n');
		for (line in lines) CliIo.stderr('$line\n');
	}

	private static function names(answers: Array<BuildAnswer>): String {
		return [for (a in answers) a.oracle.hxml].join(', ');
	}

	/** Whether `answer`'s build parsed `file`. */
	private static function parsedBy(answer: BuildAnswer, file: String): Bool {
		return answer.parsed.contains(OracleCoverage.canonical(Sys.getCwd(), file));
	}

	/** Whether `answer` is a typecheck that passed. */
	private static function confirmed(answer: BuildAnswer): Bool {
		return answer.outcome?.match(Confirmed) == true;
	}

	/**
	 * Whether the write broke a build of `after` and was put back: each red build is compiled again over the tree with the
	 * write rolled back, and one green there was broken by the write. With none, the write is replayed and every red build
	 * named as judging nothing.
	 */
	private static function putBackIfBroken(op: String, journal: WriteJournal, after: Array<BuildAnswer>, parallel: Int): Bool {
		final red: Array<BuildAnswer> = [for (a in after) if (a.outcome?.match(Rejected(_)) == true) a];
		if (red.length == 0) return false;
		final written: Array<JournalState> = journal.current();
		journal.rollback();
		final before: Array<BuildAnswer> = compile([for (r in red) r.oracle], parallel);
		final broken: Array<BuildAnswer> = [for (k => r in red) if (confirmed(before[k])) r];
		if (broken.length > 0) {
			putBack(op, broken, 'the write breaks ${names(broken)}, which typechecked before it');
			return true;
		}
		journal.replay(written);
		for (r in red) CliIo.stderr('apq $op: ${r.oracle.hxml} does not typecheck before the write either — it judges nothing\n');
		return false;
	}

	/**
	 * Settle `unreached`, written sources no build parsed, by naming each to every build whose class path holds it: a build
	 * that compiles it green joins `vouching`; a CREATED one no build compiles puts the write back (answers false); an
	 * existing one, or one no class path holds, stays unverified.
	 */
	private static function keptUnreached(
		op: String, journal: WriteJournal, oracles: Array<OracleConfig>, unreached: Array<String>, vouching: Array<String>, parallel: Int
	): Bool {
		final named: Array<BuildAnswer> = compile(naming(oracles, unreached), parallel);
		final created: Array<String> = [for (o in journal.originals()) if (o.content == null) o.path];
		for (file in unreached) {
			final holders: Array<BuildAnswer> = [for (a in named) if (parsedBy(a, file)) a];
			final green: Array<BuildAnswer> = holders.filter(confirmed);
			if (holders.length == 0) {
				CliIo.stderr('apq $op: unverified — $file is compiled by no configured build\n');
			} else if (green.length > 0) {
				for (a in green) if (!vouching.contains(a.oracle.hxml)) vouching.push(a.oracle.hxml);
			} else if (created.contains(file)) {
				journal.rollback();
				putBack(op, holders, 'the written $file typechecks in no configured build that compiles it');
				return false;
			} else {
				printErrors(op, holders);
				CliIo.stderr('apq $op: unverified — $file typechecks in no configured build that names it\n');
			}
		}
		return true;
	}

}

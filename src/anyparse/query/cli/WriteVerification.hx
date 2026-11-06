package anyparse.query.cli;

import anyparse.check.LintConfig;
import anyparse.check.oracle.CompilerOracle;
import anyparse.check.oracle.HaxeSpawn;
import anyparse.check.oracle.OracleCache;
import anyparse.check.oracle.OracleCoverage;
import anyparse.check.oracle.OracleDeclaration;
import anyparse.query.ExitCode;
import anyparse.query.LintFixSafePass;
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
 * rolled back, unless its errors blame a file the run created (nothing of it existed to break), and one red either way
 * judges nothing (`CompilerOracle.judging`'s rule). A run that only created modules compiles just the builds whose class
 * paths hold one of them (`holding`), each as configured, since a build may read a folder in ways nothing spells (a macro
 * walking it); a module none of them parsed is then named to the holders, the cheapest first, until one typechecks it,
 * and a rejection from one holder is not final, since a cheap build may lack the module's dependencies. It runs by default
 * only for a run that created or deleted a file, and for any write under `--verify`: a compile of every build costs more
 * than most in-place edits are worth.
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
		if (changed.length == 0 || (!forced && !journal.createdOrDeleted())) return exit;
		final oracles: Array<OracleConfig> = try {
			oraclesOf(changed);
		} catch (exception: ConfigConflict) {
			journal.rollback();
			CliIo.stderr('apq $op: the project config names two files — every file put back\n');
			throw exception;
		} catch (exception: Exception) {
			CliIo.stderr('apq $op: unverified — the apq.json naming the builds could not be read: ${exception.message}\n');
			return exit;
		}
		if (oracles.length != 0) return try {
			judge(op, journal, oracles, changed, exit);
		} catch (exception: Exception) {
			journal.rollback();
			CliIo.stderr('apq $op: the typecheck after the write threw: ${exception.message} — every file put back\n');
			ExitCode.EXIT_RUNTIME;
		}
		CliIo.stderr('apq $op: unverified — no "compilerOracle" in apq.json covers the written files\n');
		return exit;
	}

	/** Every configured build the `apq.json` of each of `paths` names, each once. */
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
		final created: Array<String> = createdAmong(journal, sources);
		// a run of created modules only: a build whose class paths hold none of them cannot read any
		final onlyCreated: Bool = created.length > 0 && created.length == changed.length;
		final after: Array<BuildAnswer> = compile(onlyCreated ? holding(oracles, sources) : oracles, parallel, created);
		reportUnavailable(op, after);
		if (putBackIfBroken(op, journal, after, parallel, created)) return ExitCode.EXIT_RUNTIME;
		final vouching: Array<String> = [
			for (a in after) if (confirmed(a) && (sources.length == 0 || sources.exists(s -> parsedBy(a, s)))) a.oracle.hxml
		];
		// only a build that typechecks the written tree can judge a module named to it
		final judges: Array<OracleConfig> = [for (a in after) if (confirmed(a)) a.oracle];
		final unreached: Array<String> = [for (s in sources) if (!after.exists(a -> parsedBy(a, s))) s];
		if (judges.length > 0 && unreached.length > 0 && !settleUnreached(op, journal, judges, unreached, vouching, onlyCreated, parallel))
			return ExitCode.EXIT_RUNTIME;
		final count: Int = vouching.length;
		if (count > 0)
			CliIo.stderr('apq $op: verified by $count configured build${CliIo.plural(count)}\n')
		else if (judges.length == 0)
			CliIo.stderr('apq $op: unverified — no configured build could judge the write\n');
		return exit;
	}

	/** `oracles` compiled with `-v`, `parallel` at a time: each verdict, with what it parsed. */
	private static function compile(oracles: Array<OracleConfig>, parallel: Int, created: Array<String>): Array<BuildAnswer> {
		final readings: Array<OracleReading> = CompilerOracle.typecheckEachReading(
			oracles, false, parallel, errors -> created.exists(file -> LintFixSafePass.blames(errors, file))
		);
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
	private static function putBackIfBroken(
		op: String, journal: WriteJournal, after: Array<BuildAnswer>, parallel: Int, created: Array<String>
	): Bool {
		final red: Array<BuildAnswer> = [for (a in after) if (a.outcome?.match(Rejected(_)) == true) a];
		if (red.length == 0) return false;
		final blamed: Array<BuildAnswer> = [for (a in red) if (blames(a, created)) a];
		final written: Array<JournalState> = journal.current();
		journal.rollback();
		if (blamed.length > 0) {
			putBack(op, blamed, 'the created module does not typecheck in ${names(blamed)}');
			return true;
		}
		final before: Array<BuildAnswer> = compile([for (r in red) r.oracle], parallel, []);
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
		final created: Array<String> = createdAmong(journal, unreached);
		final named: Array<BuildAnswer> = compile(naming(oracles, unreached), parallel, created);
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

	/** Whether the compiler errors of `answer` blame one of `files`. */
	private static function blames(answer: BuildAnswer, files: Array<String>): Bool {
		return switch answer.outcome {
			case Rejected(errors): files.exists(file -> LintFixSafePass.blames(errors, file));
			case _: false;
		};
	}

	/** The files of `sources` that did not exist before the run. */
	private static function createdAmong(journal: WriteJournal, sources: Array<String>): Array<String> {
		final before: Array<JournalState> = journal.originals();
		return [for (s in sources) if (before.exists(o -> o.path == s && o.content == null)) s];
	}

	/** The sources a build's explicit class paths hold: what a compile of it can be told apart by, without running one. */
	private static function sourcesOf(oracle: OracleConfig): Int {
		return sourcesIn(oracle).length;
	}

	/** `oracles` with the build holding the fewest sources first, ties in the configured order. */
	private static function cheapestFirst(oracles: Array<OracleConfig>): Array<OracleConfig> {
		final weighed: Array<{ oracle: OracleConfig, weight: Int, order: Int }> = [
			for (i => oracle in oracles) { oracle: oracle, weight: sourcesOf(oracle), order: i }
		];
		weighed.sort((a, b) -> a.weight != b.weight ? a.weight - b.weight : a.order - b.order);
		return [for (w in weighed) w.oracle];
	}

	/**
	 * Name the created `sources` to the builds whose class path holds them, the cheapest first, each build only the modules no earlier
	 * one vouched for. A green build that parsed a module vouches for it (`vouching`); a rejection that blames a created file is kept and
	 * the next build tried, with no plain retry of it. Answers true when every module is vouched for, false when the run was put back (no
	 * build vouches for a module and one blamed it, with no compile of the tree without the write), null when a module is left open.
	 */
	private static function namedCheapestFirst(
		op: String, journal: WriteJournal, oracles: Array<OracleConfig>, sources: Array<String>, vouching: Array<String>, parallel: Int
	): Null<Bool> {
		final blamed: Array<BuildAnswer> = [];
		var pending: Array<String> = sources.copy();
		for (oracle in cheapestFirst(oracles)) {
			if (pending.length == 0) break;
			final asked: Array<OracleConfig> = naming([oracle], pending);
			if (asked.length == 0) continue;
			final answer: BuildAnswer = compile(asked, parallel, sources)[0];
			if (confirmed(answer)) {
				final vouched: Array<String> = pending.filter(file -> parsedBy(answer, file));
				if (vouched.length > 0 && !vouching.contains(oracle.hxml)) vouching.push(oracle.hxml);
				pending = pending.filter(file -> !vouched.contains(file));
			} else if (blames(answer, pending)) {
				blamed.push(answer);
			}
		}
		if (pending.length == 0) return true;
		if (blamed.length == 0) return null;
		journal.rollback();
		putBack(op, blamed, 'the written ${pending.join(', ')} typechecks in no configured build that compiles it');
		return false;
	}

	/** Say, for each build of `answers` that could not typecheck at all, why. */
	private static function reportUnavailable(op: String, answers: Array<BuildAnswer>): Void {
		for (a in answers) switch a.outcome {
			case Unavailable(reason):
				CliIo.stderr('apq $op: ${a.oracle.hxml} could not typecheck the write: $reason\n');
			case _:
		}
	}

	/** The sources under the explicit class paths of `oracle`, as the canonical paths the class paths spell. */
	private static function sourcesIn(oracle: OracleConfig): Array<String> {
		final out: Array<String> = [];
		for (root in OracleCache.classPaths(oracle.hxml, oracle.dir)) collectSources(OracleCoverage.canonical(Sys.getCwd(), root), out);
		return out;
	}

	private static function collectSources(dir: String, into: Array<String>): Void {
		#if (sys || nodejs)
		if (!sys.FileSystem.exists(dir) || !sys.FileSystem.isDirectory(dir)) return;
		for (name in sys.FileSystem.readDirectory(dir)) {
			final path: String = Path.join([dir, name]);
			if (sys.FileSystem.isDirectory(path))
				collectSources(path, into);
			else if (OracleCoverage.isSource(path))
				into.push(path);
		}
		#end
	}

	/**
	 * The builds of `oracles` whose class paths (the standard library and the libraries included)
	 * hold one of `files`; all of them when none does, since nothing then says what reads the files.
	 */
	private static function holding(oracles: Array<OracleConfig>, files: Array<String>): Array<OracleConfig> {
		final held: Array<OracleConfig> = [for (oracle in oracles) if (holdsAny(oracle, files)) oracle];
		return held.length > 0 ? held : oracles;
	}

	/**
	 * Whether a class path of `oracle` is a folder above one of `files`; true when the compiler could not be asked. Whatever
	 * such a build reads from that folder (a lookup, a shadow, a macro walking it) is only learnt by compiling it.
	 */
	private static function holdsAny(oracle: OracleConfig, files: Array<String>): Bool {
		final roots: Null<Array<String>> = OracleCache.classRoots(oracle.hxml, oracle.dir);
		if (roots == null) return true;
		final base: String = oracle.dir ?? Sys.getCwd();
		for (root in roots) {
			final dir: String = OracleCoverage.canonical(base, root);
			final prefix: String = dir.endsWith('/') ? dir : '$dir/';
			if (files.exists(file -> OracleCoverage.canonical(Sys.getCwd(), file).startsWith(prefix))) return true;
		}
		return false;
	}

	/**
	 * Settle `unreached`, the written sources no build parsed, in the builds of `judges` that typechecked the tree: a run of
	 * created modules names them to the cheapest holder first, anything else (or what that leaves open) to every holder
	 * (`keptUnreached`). Answers false when the write was put back.
	 */
	private static function settleUnreached(
		op: String, journal: WriteJournal, judges: Array<OracleConfig>, unreached: Array<String>, vouching: Array<String>,
		onlyCreated: Bool, parallel: Int
	): Bool {
		final named: Null<Bool> = onlyCreated ? namedCheapestFirst(op, journal, judges, unreached, vouching, parallel) : null;
		return named ?? keptUnreached(op, journal, judges, unreached, vouching, parallel);
	}

}

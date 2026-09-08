import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin;
import anyparse.query.LintDiff;
import haxe.Exception;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

/**
 * The static-target portability probe for the anyparse core: parse, writer
 * round-trip and every builtin check, built for `--jvm` straight out of `src/`
 * with no `-lib hxnodejs` and no stubs. See `docs/testing.md` § "The core stays
 * target-independent" for the two failure modes it exists to catch.
 *
 * A JVM is needed to RUN it, never to ship anyparse — the point is that the core
 * compiles for a target whose typer is stricter than js and neko, which is how a
 * `js.node` leak or a structure-unification regression gets caught early.
 *
 * Paths come from argv; with none it reads a default slice of its own source tree.
 */
final class JvmPortability {

	/** One decimal place — the probe reports tens of seconds, not microbenchmarks. */
	private static inline final ROUND_SCALE: Float = 10;

	/**
	 * What the census numbers are, printed beside them every run.
	 *
	 * The probe's `violations` count was quoted twice in a row as a fixed expectation and was
	 * wrong both times — 1183 when the tree said 1177, then 1177 when it said 929 — because it
	 * had been measured on the commit BEFORE the one it was written against. It is not an
	 * invariant and never was: it is a function of the whole tree, so a doc reflow or an
	 * autofix moves it with nothing else changing. The gate is `wrote == files` and `threw ==
	 * 0`; everything on the census line is a reading, and a reading carries the commit it was
	 * taken on.
	 */
	private static inline final CENSUS_NOTE: String =
		'a reading of THIS tree, not an invariant — take it on your own base, never quote another commit\'s';

	/** The default scope: the two packages whose portability actually regressed. */
	private static final DEFAULT_SCOPE: Array<String> = ['src/anyparse/query', 'src/anyparse/check'];

	/** The project's writer settings, threaded in so the probe writes the way `hxq fmt` does. */
	private static final CONFIG: String = 'hxformat.json';

	public static function main(): Void {
		final args: Array<String> = Sys.args();
		final paths: Array<String> = args.length > 0 ? args : collectAll(DEFAULT_SCOPE);
		final files: Array<{ file: String, source: String }> = [
			for (path in paths) { file: path, source: File.getContent(path) }
		];
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		final opts: Null<String> = FileSystem.exists(CONFIG) ? File.getContent(CONFIG) : null;
		// The writer is exercised for COVERAGE, not for byte-equality: that is `hxq fmt
		// --list`'s job and the suite's. `threw` is the number that has to stay 0 —
		// `writeRoundTrip` throws only on a parse failure or a comment loss, never on a
		// formatting difference. The project `hxformat.json` is threaded in because the
		// writer's comment-capture seams are config-dependent: under compiled defaults
		// `PreferLocalFunction.hx` drops a line comment that survives under the project
		// config, so a probe that passed no options would sit at a permanent threw=1 and
		// train the reader to ignore the one number it exists to report.
		// Phase timings are printed because this probe is the battery's second
		// largest step (about 40s of 155s: 8s to compile, 31s to run) and was
		// otherwise a black box — "the JVM is slow" is not a finding anyone can
		// act on, "the round trip is 22s of it" is.
		final readAt: Float = Sys.time();
		var wrote: Int = 0;
		final threw: Array<String> = [];
		for (f in files) {
			try {
				if (plugin.writeRoundTrip(f.source, opts) != null) wrote++;
			} catch (exception: Exception) {
				threw.push('${f.file}: ${exception.message}');
			}
		}
		final wroteAt: Float = Sys.time();
		// The config resolver is what makes the finding count MEAN something. Without it
		// `Linter.run` skips its per-file enablement pass entirely, so every registered rule
		// counts — including the 42 that declare `Check.DefaultOff` and are therefore OFF
		// unless a project opts in, which made registering one move this number by its whole
		// finding count with nothing in the code having changed. Measured on `1c225caf`: 927
		// config-blind against 839 here, and the 88-finding gap is exactly two rules this
		// project does not enable — `asymmetric-branch-braces` (86) and
		// `default-repeated-argument` (2) — confirmed by re-running `apq lint` over the same
		// two directories with every rule force-enabled. (T783 had already measured the same
		// mechanism twice at 893 -> 1180.) It also buys the probe real coverage, since
		// `LintConfig.discover` and `LintConfig.enabledFor` are core code the probe did not
		// compile before. What it does NOT buy is comparability with `hxq lint`: that run
		// joins a `SymbolIndex` over the declared resolution roots, which the cross-file
		// checks read and this probe has no business building.
		final configByDir: Map<String, LintConfig> = [];
		function resolveConfig(file: String): LintConfig {
			final dir: String = Path.directory(file);
			final cached: Null<LintConfig> = configByDir[dir];
			if (cached != null) return cached;
			final discovered: LintConfig = LintConfig.discover(file);
			configByDir[dir] = discovered;
			return discovered;
		}
		final violations: Array<Violation> = Linter.run(files, plugin, null, resolveConfig, true);
		final lintedAt: Float = Sys.time();
		// Two lines, because the numbers answer two different questions and one of them was
		// being read as the other. `wrote == files` and `threw == 0` is the GATE — the
		// invariant this probe exists to defend. Everything on the census line is a reading of
		// the tree it happened to run over, stamped with the commit so a copy taken elsewhere
		// is visibly a copy.
		Sys.println('gate: files=${files.length} wrote=$wrote threw=${threw.length} lintdiff=${lintDiffProbe()}');
		Sys.println('census @ ${head()}: checks=${Linter.builtins().length} findings=${violations.length} — $CENSUS_NOTE');
		Sys.println('  phases: roundtrip=${seconds(wroteAt - readAt)}s lint=${seconds(lintedAt - wroteAt)}s');
		for (failure in threw) Sys.println('  threw $failure');
	}

	/** One decimal place — the probe reports tens of seconds, not microbenchmarks. */
	private static function seconds(delta: Float): String {
		return '${Math.round(delta * ROUND_SCALE) / ROUND_SCALE}';
	}

	/**
	 * The commit this run measured — `git describe --always --dirty` — or `unknown`.
	 *
	 * Stamped on the census line so a number copied into a queue header, a doc or a brief
	 * carries the tree it came from. That is the whole remedy for the failure `CENSUS_NOTE`
	 * records: both wrong quotes were RIGHT numbers taken one commit early, and neither the
	 * writer nor the next reader had anything to check them against.
	 *
	 * A failure is not an error — a tarball, a machine without git, a checkout with no commit
	 * all answer `unknown`, and the probe's verdict never depended on this. Measured: with git
	 * off `PATH` and from outside a repository the probe still exits 0 and prints
	 * `census @ unknown`, with nothing on the console.
	 *
	 * `close()` sits on the success path only, and deliberately: the one throw this can meet
	 * in practice is `new Process` failing to find git, which leaves no handle to close. A
	 * throw from a SPAWNED git would strand one for the seconds until the probe exits, and
	 * Haxe has no `finally` to buy that back without a nullable holder the dead-store check
	 * then reports. `git describe` also writes at most a line, far inside the pipe buffer, so
	 * reading stdout to EOF without draining stderr cannot deadlock here.
	 */
	private static function head(): String {
		try {
			final git: Process = new Process('git', ['describe', '--always', '--dirty']);
			final first: String = git.stdout.readAll().toString().split('\n')[0];
			final code: Int = git.exitCode();
			git.close();
			return code == 0 && first != '' ? first : 'unknown';
		} catch (exception: Exception) {
			return 'unknown';
		}
	}

	/**
	 * Round-trip a two-record report through `LintDiff` and report the surplus
	 * it finds, as `<added>+<removed>-`. `1+0-` is the expected reading: the
	 * duplicate-code pair differs only in a `./` and a line number, which both
	 * normalizations erase, so only the new dead-code record is a finding.
	 *
	 * Haxe compiles only what `-main` reaches, so without this call neither
	 * `LintDiff` nor its macro-generated ByName JSON parser is built by the
	 * probe at all — it would pass green while proving nothing about either,
	 * and `MessageMask` in particular is written against a byte-string
	 * target's string model. The em dash is in the fixture so that scan
	 * actually runs over multi-byte input on whatever target the probe is
	 * built for.
	 */
	private static function lintDiffProbe(): String {
		final tail: String = ' — extract a shared helper (report-only, cross-file)';
		final base: String = '[{"file": "a.hx", "line": 1, "col": 1, "severity": "info", "rule": "duplicate-code",'
			+ ' "message": "4 statements duplicated from ./b.hx:501$tail"}]';
		final grown: String = '[{"file": "a.hx", "line": 1, "col": 1, "severity": "info", "rule": "duplicate-code", "message": "4 '
			+ 'statements duplicated from b.hx:733$tail"}, {"file": "c.hx", "line": 9, "col": 1, '
			+ '"severity": "warning", "rule": "dead-code", "message": "unreachable statement"}]';
		final identities: LintMessageIdentities = Linter.messageIdentities();
		final result: LintDiffResult = LintDiff.compare(
			LintDiff.tally(LintDiff.parseReport(base), '', identities), LintDiff.tally(LintDiff.parseReport(grown), '', identities)
		);
		return '${result.addedTotal}+${result.removedTotal}-';
	}

	/** Every `.hx` under each of `dirs`, recursively. */
	private static function collectAll(dirs: Array<String>): Array<String> {
		final out: Array<String> = [];
		for (dir in dirs) collect(dir, out);
		return out;
	}

	private static function collect(dir: String, out: Array<String>): Void {
		for (name in FileSystem.readDirectory(dir)) {
			final path: String = '$dir/$name';
			if (FileSystem.isDirectory(path))
				collect(path, out);
			else if (Path.extension(name) == 'hx')
				out.push(path);
		}
	}

}

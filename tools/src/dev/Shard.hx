package dev;

import anyparse.query.Cli.TestSummaryResult;
import anyparse.query.ShardPlan;
import anyparse.query.cli.CliIo;
import anyparse.query.cli.TestTranscript;
import devkit.Args;
import devkit.Cmd.cmd;
import devkit.Command;
import devkit.FixtureCache;
import devkit.Pool;
import devkit.Result;
import devkit.TmpLifecycle;
import haxe.Exception;
import haxe.Timer;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * `dev shard` — the whole utest suite as N parallel `APQ_TEST` shards, each registered class run exactly once. The split
 * and its gates are `ShardPlan`'s, over the class list the runner itself prints (`--list-classes`); this tool spawns the
 * shards, reconciles each transcript with its shard's exit status, and ends on ONE verdict line,
 * `suite-shard: PASS — …` or `suite-shard: FAILED — <reasons>`. Rationale and flags: `docs/testing.md` § "Parallel
 * shards: one suite, N processes".
 */
@:nullSafety(Strict)
final class Shard {

	public static inline final USAGE: String = 'usage: dev shard [-n <N>] [--verify | --expect <tests>/<assertions>] [--plan-only] [--bin <test.js>] [--keep] '
		+ '[--timings <tsv>] [--repo <tree>]';

	/** The shard count when `-n` names none. */
	public static inline final DEFAULT_SHARDS: Int = 4;

	/** The prefix `devkit.TmpLifecycle` claims this tool's work directory under, and sweeps it by. */
	private static inline final WORK_PREFIX: String = 'apq-suite-shard';

	/** The last green run's per-class timings: the weights the next plan balances on. */
	private static inline final WEIGHTS: String = 'bin/.suite-timings.tsv';

	/**
	 * The test tree whose `*Test.hx` files the runner's class list must match one for one: the build macro
	 * (`testkit.TestDiscovery`) registers exactly one class per such file, so another count is a binary built from another tree.
	 */
	private static inline final TEST_ROOT: String = 'test';

	/** The file-name ending of a test module under `TEST_ROOT`. */
	private static inline final TEST_FILE_SUFFIX: String = 'Test.hx';

	/**
	 * What one shard may run before it is killed. The process driver bounds its own wait by its jobs' timeouts, and a
	 * shard that outlives this one is wedged, not slow.
	 */
	private static inline final SHARD_TIMEOUT_MS: Int = 2 * 60 * 60 * 1000;

	private static inline final MS_PER_SECOND: Int = 1000;
	private static inline final MS_PER_TENTH: Int = 100;

	/** The widths of a shard line's class, test and assertion columns. */
	private static inline final CLASS_WIDTH: Int = 4;

	private static inline final TEST_WIDTH: Int = 5;
	private static inline final ASSERTION_WIDTH: Int = 6;
	private static inline final MILLIS_WIDTH: Int = 3;

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final short: Null<String> = args.option('-n');
		final long: Null<String> = args.option('--shards');
		final verify: Bool = args.flag('--verify');
		final expectText: Null<String> = args.option('--expect');
		final planOnly: Bool = args.flag('--plan-only');
		final keep: Bool = args.flag('--keep');
		final bin: Null<String> = args.option('--bin');
		final timings: Null<String> = args.option('--timings');
		final repo: String = Repo.resolve(args.option('--repo'));
		args.done();
		final shardsText: String = short ?? long ?? '$DEFAULT_SHARDS';
		if (!isCount(shardsText)) throw new UsageError('-n expects a positive integer, got \'$shardsText\'');
		final shards: Int = Std.parseInt(shardsText) ?? 0;
		if (shards < 1) throw new UsageError('-n must be >= 1');
		if (verify && expectText != null)
			throw new UsageError('pass --verify or --expect, not both — --verify measures the pair --expect asserts');
		final own: String = Path.join([repo, 'bin/test.js']);
		// a relative --bin names a file in the tree, whatever the working directory
		final testJs: String = if (bin == null)
			own
		else if (Path.isAbsolute(bin))
			bin
		else
			Path.join([repo, bin]);
		if (!FileSystem.exists(testJs))
			throw new UsageError('no test runner at $testJs — build it with \'haxe test-js.hxml\' (or pass --bin)');
		// a private runner's engine sits beside it: the shards' own `hxq` calls must not fall back to the shared one
		final sibling: String = Path.join([Path.directory(FileSystem.fullPath(testJs)), 'apq.js']);
		if ((Sys.getEnv('HXQ_BIN') ?? '') == '' && testJs != own && FileSystem.exists(sibling)) Sys.putEnv('HXQ_BIN', sibling);
		return run({
			repo: repo,
			testJs: testJs,
			shards: shards,
			verify: verify,
			expect: expectText == null ? null : parseExpect(expectText),
			planOnly: planOnly,
			keep: keep,
			timings: timings,
			fixtureCache: fixtureCacheOfEnv(),
			print: Sys.println,
			warn: line -> Sys.stderr().writeString('$line\n')
		});
	}

	/**
	 * Run `job` in a work directory of its own, claimed after the startup sweep: removed when the run is green and not
	 * kept, otherwise kept and named on stderr. Answers the exit status.
	 */
	public static function run(job: ShardJob): Int {
		final dirs: TmpLifecycle = TmpLifecycle.fromEnv();
		dirs.startupSweep(job.repo);
		final work: String = dirs.claim(WORK_PREFIX);
		final keep: Bool = job.keep || job.planOnly;
		final status: Int = try execute(job, work) catch (exception: Exception) {
			release(dirs, work, keep, 1, job.warn);
			throw exception;
		};
		release(dirs, work, keep, status, job.warn);
		return status;
	}

	/** The fixture-cache store the shards replay their probe compiles from, as the environment names it; null when it says not to. */
	public static function fixtureCacheOfEnv(): Null<String> {
		if (nonEmptyEnv('APQ_SUITE_NO_FIXTURE_CACHE') != null) return null;
		final home: String = Sys.getEnv('XDG_CACHE_HOME') ?? Path.join([Sys.getEnv('HOME') ?? '', '.cache']);
		return nonEmptyEnv('APQ_SUITE_FIXTURE_CACHE') ?? Path.join([home, 'anyparse/fixture-cache']);
	}

	/** `<tests>/<assertions>`, two counts and one slash, or a `UsageError`. */
	public static function parseExpect(text: String): SuiteCounts {
		final pair: Array<String> = text.split('/');
		if (pair.length != 2 || !isCount(pair[0]) || !isCount(pair[1]))
			throw new UsageError('--expect wants TESTS/ASSERTIONS (two integers, one slash), got \'$text\'');
		return { tests: Std.parseInt(pair[0]) ?? 0, assertions: Std.parseInt(pair[1]) ?? 0 };
	}

	/**
	 * How many `*Test.hx` files sit in a package directory under `root` — a file at `root` itself is an entry point, never a
	 * test — or null when there is no directory `root`.
	 */
	public static function testFileCount(root: String): Null<Int> {
		if (!FileSystem.exists(root) || !FileSystem.isDirectory(root)) return null;
		function count(dir: String, nested: Bool): Int {
			var total: Int = 0;
			for (entry in FileSystem.readDirectory(dir)) {
				final full: String = Path.join([dir, entry]);
				if (FileSystem.isDirectory(full))
					total += count(full, true);
				else if (nested && entry.endsWith(TEST_FILE_SUFFIX))
					total++;
			}
			return total;
		}
		return count(root, false);
	}

	/**
	 * `<ms>\t<tests>\t<class>` rows (`APQ_TEST_TIMING`), summed per class — a class dealt as slices has a row per shard
	 * that ran one — slowest first, then by name.
	 */
	public static function mergeTimings(rows: String): String {
		final ms: Map<String, Int> = [];
		final tests: Map<String, Int> = [];
		final classes: Array<String> = [];
		for (line in rows.split('\n')) {
			final cells: Array<String> = line.split('\t');
			if (cells.length != 3) continue;
			final cls: String = cells[2];
			if (!ms.exists(cls)) classes.push(cls);
			ms[cls] = (ms[cls] ?? 0) + (Std.parseInt(cells[0]) ?? 0);
			tests[cls] = (tests[cls] ?? 0) + (Std.parseInt(cells[1]) ?? 0);
		}
		classes.sort((a, b) -> {
			final slower: Int = (ms[b] ?? 0) - (ms[a] ?? 0);
			slower != 0 ? slower : Reflect.compare(a, b);
		});
		return [for (cls in classes) '${ms[cls]}\t${tests[cls]}\t$cls\n'].join('');
	}

	/** Plan, run and report; answers the exit status. Every file it writes goes into `work`. */
	private static function execute(job: ShardJob, work: String): Int {
		final split: Null<ShardSplit> = split(job, work);
		if (split == null) return 1;
		if (job.planOnly) {
			job.print('dev shard: ${split.classes} classes over ${job.shards} shards (class parity OK)');
			job.print('  plan: ${Path.join([work, 'assigned.txt'])}');
			for (s => list in split.lists) job.print('  shard $s: ${list.length} classes -> ${Path.join([work, 'shard$s.list'])}');
			return 0;
		}
		final tally: String = Path.join([work, 'fixture-cache.tally']);
		final shim: Null<String> = job.fixtureCache == null ? null : fixtureShim(job, work, tally);
		final path: String = Sys.getEnv('PATH') ?? '';
		final verdict: Verdict = new Verdict();
		final started: Float = Timer.stamp();
		final runs: Array<Result> = Pool.of(job.shards).map(
			[for (s in 0...job.shards) s],
			s ->
				callerGc(
					cmd('node ${job.testJs}')
						.at(job.repo)
						.env('PATH', shim == null ? path : '$shim:$path')
						.env('APQ_TEST', split.filters[s])
						.env('APQ_TEST_TIMING', Path.join([work, 'shard$s.timing']))
						.timeout(SHARD_TIMEOUT_MS)
				)
		);
		final elapsed: Int = Math.round((Timer.stamp() - started) * MS_PER_SECOND);
		final sum: Tally = {
			tests: 0,
			assertions: 0,
			failures: 0,
			errors: 0
		};
		for (s => result in runs) add(sum, reportShard(job, work, s, split.lists[s].length, result, verdict));
		job.print(
			'--- suite-shard: ${split.classes} classes / ${sum.tests} tests / ${sum.assertions} assertions / ${sum.failures} failures / '
			+ '${sum.errors} errors in ${Std.int(elapsed / MS_PER_SECOND)}.${pad(elapsed % MS_PER_SECOND, MILLIS_WIDTH, '0')}s '
			+ 'across ${job.shards} shards ---'
		);
		job.print(
			if (job.fixtureCache == null)
				'fixture cache: off (APQ_SUITE_NO_FIXTURE_CACHE)'
			else if (shim == null)
				'fixture cache: unavailable, every compile ran for real'
			else
				'fixture cache: ${FixtureCache.tally(tally) ?? ''}'
		);
		handTotals(job, sum);
		if (verdict.partial) job.warn('dev shard: the totals above are a SUM OF WHAT RAN, not a total — at least one shard did not finish');
		if (sum.failures != 0 || sum.errors != 0) verdict.red = true;
		final parity: String = crossCheck(job, work, sum, verdict) ?? 'counts not cross-checked (class parity OK: ${split.classes} placed; ${split.producerNote})';
		refreshTimings(job, work, verdict);
		final stale: Null<String> = CliIo.testJsStaleness(job.testJs, job.repo);
		if (stale != null) job.warn('dev shard: WARNING: $stale');
		job.print('parity: $parity');
		job.print(
			verdict.red
				? 'suite-shard: FAILED — ${verdict.reasons.length == 0 ? 'see the messages above' : verdict.reasons.join('; ')}'
				: 'suite-shard: PASS — ${split.classes} classes / ${sum.tests} tests / ${sum.assertions} assertions over ${job.shards} shards'
		);
		return verdict.red ? 1 : 0;
	}

	/**
	 * The shard plan, written into `work` (`classes.txt`, `assigned.txt`, `shard<s>.filter`, `shard<s>.list`); null, its
	 * refusal said on stderr, when the runner cannot list its classes, `ShardPlan` refuses, or the list's length is not the
	 * number of `*Test.hx` files on disk.
	 */
	private static function split(job: ShardJob, work: String): Null<ShardSplit> {
		final listed: Result = cmd('node ${job.testJs} --list-classes').at(job.repo).run();
		if (!listed.ok) {
			job.warn((listed.err + listed.failure).rtrim());
			job.warn('dev shard: ${job.testJs} could not list its registered classes');
			return null;
		}
		final classesFile: String = Path.join([work, 'classes.txt']);
		File.saveContent(classesFile, listed.out);
		final classes: Array<String> = [for (line in listed.out.split('\n')) if (line.trim() != '') line.trim()];
		final weights: String = Path.join([job.repo, WEIGHTS]);
		final measured: Null<Map<String, ClassWeight>> = FileSystem.exists(weights) && FileSystem.stat(weights).size > 0
			? ShardPlan.parseWeights(File.getContent(weights))
			: null;
		final placements: Array<ShardPlacement> = switch ShardPlan.planClasses(classes, job.shards, classesFile, measured) {
			case Planned(placements): placements;
			case Refused(message):
				job.warn(message);
				return null;
		};
		File.saveContent(Path.join([work, 'assigned.txt']), ShardPlan.renderLines(placements));
		final filters: Array<String> = ShardPlan.renderFilters(placements, job.shards).split('\n').slice(0, job.shards);
		final total: Int = [for (p in placements) p.cls => true].count();
		final onDisk: Null<Int> = testFileCount(Path.join([job.repo, TEST_ROOT]));
		if (onDisk != null && total != onDisk) {
			job.warn('dev shard: the class-list producer printed $total classes, but');
			job.warn('  the test tree holds $onDisk *$TEST_FILE_SUFFIX files.');
			job.warn('  ${job.testJs} was built from another tree — rebuild it (`haxe test-js.hxml`); its list is $classesFile');
			return null;
		}
		final lists: Array<Array<String>> = [for (filter in filters) filter.split(',')];
		for (s => filter in filters) {
			File.saveContent(Path.join([work, 'shard$s.filter']), '$filter\n');
			File.saveContent(Path.join([work, 'shard$s.list']), lists[s].join('\n') + '\n');
		}
		return {
			filters: filters,
			lists: lists,
			classes: total,
			producerNote: onDisk == null
				? 'producer count not cross-checked (no $TEST_ROOT/ tree)'
				: 'producer count == *$TEST_FILE_SUFFIX files ($onDisk)'
		};
	}

	/**
	 * Prune the store `job.fixtureCache` and write the `haxe` shim that replays the shards' probe compiles from it into
	 * `work`; answers the shim's directory, or null — said on stderr — when it cannot be had.
	 */
	private static function fixtureShim(job: ShardJob, work: String, tally: String): Null<String> {
		final entries: String = job.fixtureCache ?? throw new Exception('no fixture-cache store to shim');
		FixtureCache.prune(entries, FixtureCache.maxAgeDays());
		final bindir: String = Path.join([work, 'fixture-cache-bin']);
		final why: Null<String> = try FixtureCache.shim(job.repo, entries, bindir, tally) catch (exception: Exception) {
			'fixture-cache: ${exception.message}';
		};
		if (why == null) return bindir;
		job.warn(why);
		return null;
	}

	/** Hand `sum` to the job's `counted`, when it asks for the totals. */
	private static function handTotals(job: ShardJob, sum: Tally): Void {
		final counted: Null<Tally -> Void> = job.counted;
		if (counted != null) counted(sum);
	}

	/** Save shard `s`'s transcript, print its line (and its first failure), record what is wrong; answers its counts. */
	private static function reportShard(job: ShardJob, work: String, s: Int, classes: Int, result: Result, verdict: Verdict): Tally {
		final exit: Int = result.ok ? 0 : 1;
		final log: String = Path.join([work, 'shard$s.log']);
		saveLog(log, result);
		final summary: Summarised = summarise(log, exit, job.warn);
		if (summary.rc == 1) {
			job.warn('dev shard: shard $s log is at $log');
			verdict.fail('shard $s could not be summarised');
		}
		final counts: Tally = summary.counts;
		if (summary.rc == 2) {
			verdict.partial = true;
			verdict.fail('shard $s exited $exit with no failing test in its report — it did not finish');
		}
		job.print(
			'shard $s: ${pad(classes, CLASS_WIDTH)} classes / ${pad(counts.tests, TEST_WIDTH)} tests / '
			+ '${pad(counts.assertions, ASSERTION_WIDTH)} assertions / ${counts.failures} failures / ${counts.errors} errors '
			+ '(exit $exit) in ${tenths(shardMillis(work, s))}s${summary.rc == 2 ? '  <-- did NOT finish: these counts are partial' : ''}'
		);
		if (counts.failures != 0 || counts.errors != 0) {
			final locus: Null<String> = summary.locus;
			if (locus != null) job.print('  shard $s $locus');
			verdict.fail('shard $s is red (${counts.failures} failures / ${counts.errors} errors)');
		}
		if (counts.tests == 0) {
			job.warn('dev shard: shard $s reported 0 tests — its filter matched nothing, or the run aborted before the report (see $log)');
			verdict.fail('shard $s reported 0 tests');
		}
		if (exit != 0) verdict.red = true;
		return counts;
	}

	/**
	 * `--verify` (a monolith run, its counts compared and its own verdict read) or `--expect` against the shards' `sum`;
	 * answers the parity note, or null when neither was asked for.
	 */
	private static function crossCheck(job: ShardJob, work: String, sum: Tally, verdict: Verdict): Null<String> {
		final expect: Null<SuiteCounts> = job.expect;
		if (expect != null) {
			final asked: String = '${expect.tests}/${expect.assertions}';
			if (expect.tests == sum.tests && expect.assertions == sum.assertions) return 'counts match --expect $asked';
			final pair: String = 'shards ${sum.tests}/${sum.assertions} vs --expect $asked';
			job.warn('dev shard: COUNT PARITY FAIL — $pair');
			verdict.fail('count parity FAILED — $pair');
			return 'counts DIVERGED from --expect $asked';
		}
		if (!job.verify) return null;
		// an empty APQ_TEST runs everything: a filter exported by the caller must not shrink the monolith
		final mono: Result = callerGc(cmd('node ${job.testJs}').at(job.repo).env('APQ_TEST', '')).run();
		final exit: Int = mono.ok ? 0 : mono.status ?? 1;
		final log: String = Path.join([work, 'mono.log']);
		saveLog(log, mono);
		final summary: Summarised = summarise(log, exit, job.warn);
		final m: Tally = summary.counts;
		if (summary.rc == 1) {
			job.warn('dev shard: could not summarise the monolith run — see $log');
			verdict.fail('the monolith run could not be summarised');
			return 'monolith run could not be summarised';
		}
		if (exit != 0 || m.failures != 0 || m.errors != 0) {
			final what: String = 'exit $exit, ${m.failures} failures, ${m.errors} errors';
			job.warn('dev shard: the monolith run is RED ($what) while the shards are green — see $log');
			verdict.fail('the monolith run is RED ($what) while the shards are green');
			return 'monolith run RED (${m.tests} tests / ${m.assertions} assertions / ${m.failures} failures / ${m.errors} errors)';
		}
		if (m.tests == sum.tests && m.assertions == sum.assertions)
			return 'counts verified against a monolith run (${m.tests} tests / ${m.assertions} assertions)';
		final pair: String = 'shards ${sum.tests}/${sum.assertions} vs monolith ${m.tests}/${m.assertions}';
		job.warn('dev shard: COUNT PARITY FAIL — $pair');
		verdict.fail('count parity FAILED — $pair');
		return 'counts DIVERGED from the monolith run (${m.tests} tests / ${m.assertions} assertions)';
	}

	/**
	 * Merge the shards' timing rows into `--timings` when asked, and into the plan's weights after a green, complete
	 * run — a red or partial one under-weights what it never finished.
	 */
	private static function refreshTimings(job: ShardJob, work: String, verdict: Verdict): Void {
		final merged: String = mergeTimings([
			for (s in 0...job.shards) {
				final file: String = Path.join([work, 'shard$s.timing']);
				FileSystem.exists(file) ? File.getContent(file) : '';
			}
		].join('\n'));
		final timings: Null<String> = job.timings;
		if (timings != null) File.saveContent(timings, merged);
		if (verdict.red || verdict.partial || merged == '') return;
		// staged beside the target: a rename never crosses a filesystem, and a reader never sees half a file
		final target: String = Path.join([job.repo, WEIGHTS]);
		final staged: String = '$target.${js.Node.process.pid}.tmp';
		File.saveContent(staged, merged);
		FileSystem.rename(staged, target);
	}

	/**
	 * The counts of the transcript `log`, reconciled with the exit status `exit` its run returned: `rc` 0 when they
	 * agree, 2 when they disagree (the run did not finish, or swallowed its own verdict), 1 when there is no report to
	 * count at all.
	 */
	private static function summarise(log: String, exit: Int, warn: String -> Void): Summarised {
		final result: TestSummaryResult = TestTranscript.parseTestSummary(File.getContent(log));
		if (!result.counted) {
			warn('dev shard: could not summarise $log — no utest report in it');
			return {
				counts: {
					tests: 0,
					assertions: 0,
					failures: 0,
					errors: 0
				},
				rc: 1,
				locus: null
			};
		}
		final disagreement: Null<String> = TestTranscript.exitStatusDisagreement(exit, result, log);
		if (disagreement != null) warn(disagreement);
		return {
			counts: {
				tests: result.tests,
				assertions: result.assertions,
				failures: result.failures,
				errors: result.errors
			},
			rc: disagreement == null ? 0 : 2,
			locus: TestTranscript.firstFailureLine(result)
		};
	}

	/** Remove `work` after a green run that is not kept; otherwise keep it — marked, when asked to be — and say where. */
	private static function release(dirs: TmpLifecycle, work: String, keep: Bool, status: Int, warn: String -> Void): Void {
		if (!keep && status == 0) {
			final refused: Null<String> = dirs.discard(work);
			if (refused != null) warn('dev shard: $refused');
			return;
		}
		if (keep) dirs.markKeep(work);
		warn('dev shard: work files kept in $work');
	}

	/** A run's transcript as one file: its stdout, its stderr, and why it gave no exit status when it gave none. */
	private static function saveLog(log: String, result: Result): Void {
		File.saveContent(log, result.out + result.err + (result.failure == '' ? '' : '${result.failure}\n'));
	}

	/**
	 * `command` under the caller's own OCaml collector settings: the process driver tunes them for every `haxe` it
	 * starts, and the suite's compiles run in the environment the suite was given.
	 */
	private static function callerGc(command: Command): Command {
		return command.env('OCAMLRUNPARAM', Sys.getEnv('OCAMLRUNPARAM') ?? Sys.getEnv('CAMLRUNPARAM') ?? '');
	}

	/** Shard `s`'s in-suite milliseconds: the sum of its `APQ_TEST_TIMING` rows, 0 when it wrote none. */
	private static function shardMillis(work: String, s: Int): Int {
		final file: String = Path.join([work, 'shard$s.timing']);
		if (!FileSystem.exists(file)) return 0;
		var ms: Int = 0;
		for (line in File.getContent(file).split('\n')) ms += Std.parseInt(line.split('\t')[0]) ?? 0;
		return ms;
	}

	private static function add(sum: Tally, counts: Tally): Void {
		sum.tests += counts.tests;
		sum.assertions += counts.assertions;
		sum.failures += counts.failures;
		sum.errors += counts.errors;
	}

	/** `ms` as whole seconds and one decimal, the decimal truncated. */
	private static function tenths(ms: Int): String {
		return '${Std.int(ms / MS_PER_SECOND)}.${Std.int((ms % MS_PER_SECOND) / MS_PER_TENTH)}';
	}

	private static function pad(n: Int, width: Int, fill: String = ' '): String {
		return '$n'.lpad(fill, width);
	}

	private static function isCount(text: String): Bool {
		return ~/^[0-9]+$/.match(text);
	}

	private static function nonEmptyEnv(name: String): Null<String> {
		final value: Null<String> = Sys.getEnv(name);
		return value == null || value == '' ? null : value;
	}

}

/** What a run found wrong so far: every reason in the order found, whether it is red, whether a shard did not finish. */
private final class Verdict {

	public final reasons: Array<String> = [];

	public var red: Bool = false;
	public var partial: Bool = false;

	public function new() {}

	/** Record `reason`, which makes the run red. */
	public function fail(reason: String): Void {
		red = true;
		reasons.push(reason);
	}

}

/** One `dev shard` run, as `Shard.run` takes it. */
typedef ShardJob = {
	var repo: String;
	var testJs: String;
	var shards: Int;
	var verify: Bool;
	var expect: Null<SuiteCounts>;
	var planOnly: Bool;
	var keep: Bool;
	var timings: Null<String>;

	/** The fixture-cache store the shards' probe compiles replay from, or null to compile everything for real. */
	var fixtureCache: Null<String>;

	/** Where a measurement or the verdict line goes (stdout). */
	var print: String -> Void;

	/** Where a refusal, a reason or an advisory goes (stderr). */
	var warn: String -> Void;

	/** Handed the run's totals once every shard has ended — a sum of what ran when a shard did not finish. */
	var ?counted: Tally -> Void;
}

/** A shard plan as the run uses it: each shard's `APQ_TEST` value and its tokens, the class total, the producer check. */
typedef ShardSplit = {
	var filters: Array<String>;
	var lists: Array<Array<String>>;
	var classes: Int;
	var producerNote: String;
}

/** A suite's test and assertion totals. */
typedef SuiteCounts = {
	var tests: Int;
	var assertions: Int;
}

/** The four counts of one transcript. */
typedef Tally = {
	var tests: Int;
	var assertions: Int;
	var failures: Int;
	var errors: Int;
}

/** One transcript summarised: its counts, how they agree with the run's exit status, and its first failure. */
typedef Summarised = {
	var counts: Tally;
	var rc: Int;
	var locus: Null<String>;
}

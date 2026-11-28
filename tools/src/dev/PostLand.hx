package dev;

import devkit.Args;
import devkit.Branches;
import devkit.Cmd.cmd;
import devkit.Command;
import devkit.CpuMeter;
import devkit.Lease;
import devkit.LeaseHistory;
import devkit.Result;
import devkit.Summary.Outcome;
import devkit.TmpLifecycle;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * The start of the run for a landed commit: the tree, the commit, the snapshot cache and whether the whole suite runs.
 * A land whose battery ran every class starts the hxcpp build alone.
 */
typedef PostLandStart = (tree: String, sha: String, cache: String, suite: Bool) -> Outcome;

/** What a `dev shard` run reports of itself: the shards it ran on and the milliseconds it took. */
typedef ShardSpan = { var shards: Int; var ms: Float; }

/**
 * The one answer to "did the whole suite pass on a commit whose land ran only the classes its change reaches": `dev land`
 * starts `dev post-land run <sha>` once the land has passed, a process that outlives the land and its lock, checks the commit
 * out into a worktree of its own, builds it and runs the whole suite there and then the whole lint (the check of the lint
 * snapshot a land carried from its base, `LintScope`). It holds no lease through all that: the build, the suite, the whole
 * lint and the hxcpp build each take a lease sized to what that phase runs. A green run leaves nothing; a red one leaves
 * `<sha>.red` in the snapshot cache, which the next land refuses on until `dev post-land clear <sha>`. The run never holds
 * the land lock, so it never delays the next land.
 */
@:nullSafety(Strict)
final class PostLand {

	public static inline final USAGE: String =
		'usage: dev post-land run <sha> [--hxcpp-only] [--repo <dir>] [--cache <dir>] | hxcpp <sha> [--repo <dir>] [--cache <dir>] | status [--cache <dir>] | clear (<sha>... | --all) [--cache <dir>]';

	private static inline final RUNNING: String = 'running';
	private static inline final RED: String = 'red';
	private static inline final SHARD_TIMEOUT_MS: Int = 3 * 60 * 60 * 1000;
	private static inline final PHASE_TIMEOUT_MS: Int = 30 * 60 * 1000;
	private static inline final MS_PER_SECOND: Float = 1000;

	/**
	 * What the whole lint is leased: a cap on its compile fan-out, one process on the node engine's cpus, not the size of a process.
	 */
	private static final LINT_ASK: Ask = {
		min: 1,
		max: 1,
		priority: 0,
		cores: Lease.NODE_CORES
	};

	private static final HXCPP_ONLY: String = '--hxcpp-only';
	private static final HXCPP_CACHE: String = 'hxcpp-compile';

	/** The directory of the snapshot cache that holds the records and the run's own copy of `dev.js`. */
	private static final DIRECTORY: String = 'post-land';

	private static final LOG: String = 'log';
	private static final PID: String = 'pid';
	private static final SCRIPT: String = 'dev.js';
	private static final WORK_PREFIX: String = 'apq-dev';

	/** The totals line `dev shard` ends its tally with. */
	private static final TOTALS: EReg = ~/--- suite-shard: \d+ classes \/ (\d+) tests \/ (\d+) assertions/;

	private static final BUILD_ROW: String = 'build';
	private static final SHARD_ROW: String = 'shard';
	private static final LINT_ROW: String = 'lint';
	private static final HXCPP_ROW: String = 'hxcpp';

	/** The line the hxcpp build prints first, naming the threads its lease granted it. */
	private static final THREADS_MARK: String = 'post-land threads: ';

	private static final THREADS_LINE: EReg = ~/^post-land threads: (\d+)$/m;

	/**
	 * The line the whole lint's own wrapper prints to stderr once its lease is granted and the lint is about to start: what stands
	 * before it is the lease wrapper's waiting text, and without it the lint never started.
	 */
	private static final LINT_MARK: String = 'post-land lint started';

	private static final LINT_START: String = 'echo "$LINT_MARK" >&2; exec "$$@"';

	/** The end of the totals line of `dev shard`: its elapsed seconds and the shards it ran on. */
	private static final SPAN: EReg = ~/ in (\d+(?:\.\d+)?)s across (\d+) shards ---/;

	/** The commits whose whole suite ended red and were not cleared. */
	public static inline function red(cache: String): Array<String> {
		return recorded(directory(cache), RED);
	}

	/**
	 * The mode every phase of a whole-suite run leases under: always the pool, whatever lease the caller of the run holds. The
	 * detached run inherits its starter's `WF_THREADS`, which `Lease.ofEnvironment` would read as a held lease and so wrap nothing.
	 */
	public static inline function phaseMode(): LeaseMode {
		return Lease.pooled();
	}

	/**
	 * `body` as the phase `name` of a post-land run, recorded in the ledger with its wall, the cpu of the processes it started and
	 * the threads it reports through the function it is given (none when it holds none the pool granted).
	 */
	public static inline function timed(cache: String, name: String, body: (Null<Int> -> Void) -> Outcome): Outcome {
		return DetachedRow.record(cache, DIRECTORY, name, body);
	}

	/** The commits whose whole suite was started, has not ended and whose process is still there. */
	public static function running(cache: String): Array<String> {
		return recorded(directory(cache)).filter(sha -> alive(cache, sha));
	}

	/**
	 * The commits whose run left a `running` record and no process: killed, slept through or reaped with the process group of
	 * the land that started it. Their whole suite never gave a verdict.
	 */
	public static function lost(cache: String): Array<String> {
		return recorded(directory(cache)).filter(sha -> !alive(cache, sha));
	}

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final cache: String = args.option('--cache') ?? Land.cacheDir(Sys.getEnv);
		final repo: Null<String> = args.option('--repo');
		final all: Bool = args.flag('--all');
		final hxcppOnly: Bool = args.flag('--hxcpp-only');
		final words: Array<String> = args.rest(['<run|hxcpp|status|clear>']);
		final verb: String = words[0];
		final shas: Array<String> = words.slice(1);
		switch verb {
			case 'run':
				if (shas.length != 1) throw new UsageError('run takes one <sha>');
				return run(Repo.resolve(repo), shas[0], cache, !hxcppOnly);
			case 'hxcpp':
				if (shas.length != 1) throw new UsageError('hxcpp takes one <sha>');
				return hxcppProbe(Repo.resolve(repo), shas[0], cache);
			case 'status':
				if (shas.length > 0) throw new UsageError('status takes no <sha>');
				for (line in statusLines(cache)) Sys.println(line);
				return 0;
			case 'clear':
				if (all == (shas.length > 0)) throw new UsageError('clear takes <sha>... or --all');
				final cleared: Array<String> = clear(cache, all ? red(cache).concat(lost(cache)) : shas);
				Sys.println('post-land: cleared ${cleared.length} record(s)${cleared.length == 0 ? '' : ': ' + cleared.join(' ')}');
				return 0;
			case _:
				throw new UsageError('unknown verb $verb');
		}
	}

	/** Why a land must not start, or null: the red commits, each with the record that names its log. */
	public static function refusal(cache: String): Null<String> {
		final shas: Array<String> = red(cache);
		if (shas.length == 0) return null;
		final shown: String = shas.join(' ');
		return 'the whole suite of the landed $shown ended red (${File.getContent(recordOf(cache, shas[0])).trim()}) — a land of the '
			+ 'fix is refused until the record is cleared: `node bin/dev.js post-land clear $shown`, then land the fix';
	}

	/** The report `status` prints: a line per record, or one line saying there is none. */
	public static function statusLines(cache: String): Array<String> {
		final lines: Array<String> = red(cache)
			.map(sha -> 'red      $sha  ${File.getContent(recordOf(cache, sha)).trim()}')
			.concat(running(cache).map(sha -> 'running  $sha'))
			.concat(
				lost(cache).map(sha -> 'LOST     $sha  no process, no verdict — the next land runs it again, or `post-land clear $sha`')
			);
		return lines.length == 0 ? ['post-land: no record'] : lines;
	}

	/** Remove the red record of each of `shas`, and what a lost run of it left; answers the ones that had one. */
	public static function clear(cache: String, shas: Array<String>): Array<String> {
		final cleared: Array<String> = [];
		final gone: Array<String> = lost(cache);
		for (sha in shas) {
			final file: String = recordOf(cache, sha);
			final red: Bool = FileSystem.exists(file);
			final wasLost: Bool = gone.contains(sha);
			if (!red && !wasLost) continue;
			if (red) FileSystem.deleteFile(file);
			if (wasLost) {
				remove(recordOf(cache, sha, RUNNING));
				remove(fileOf(cache, sha, PID));
				release(directory(cache), sha, red);
			}
			cleared.push(sha);
		}
		return cleared;
	}

	/** The tests and assertions the `dev shard` transcript `text` totals, or null when it holds no totals line. */
	public static function countsOf(text: String): Null<Array<Int>> {
		if (!TOTALS.match(text)) return null;
		final tests: Null<Int> = Std.parseInt(TOTALS.matched(1));
		final assertions: Null<Int> = Std.parseInt(TOTALS.matched(2));
		return tests == null || assertions == null ? null : [tests, assertions];
	}

	/** The shards and the milliseconds the `dev shard` transcript `text` ran on, or null when it holds no totals line. */
	public static function spanOf(text: String): Null<ShardSpan> {
		if (!SPAN.match(text)) return null;
		final shards: Null<Int> = Std.parseInt(SPAN.matched(2));
		final seconds: Float = Std.parseFloat(SPAN.matched(1));
		return shards == null || Math.isNaN(seconds) ? null : { shards: shards, ms: seconds * MS_PER_SECOND };
	}

	/**
	 * The command line of the run for `sha`: a copy of `dev.js` the run owns (a later land rebuilds the shared one).
	 * The whole-suite run holds no lease of its own, each of its phases takes the lease it needs; the hxcpp-only run is
	 * one phase, under the pool lease `mode` grants it.
	 */
	public static function argvOf(
		mode: LeaseMode, script: String, repo: String, sha: String, cache: String, suite: Bool = true
	): Array<String> {
		final words: Array<String> = ['node', script, DIRECTORY, 'run', sha, '--repo', repo, '--cache', cache];
		return suite ? words : leased(mode, Command.of(words.concat([HXCPP_ONLY])), 'post-land $sha').argv;
	}

	/**
	 * Start the whole-suite run of `sha` detached from this process and answer at once. The record `running` exists before
	 * the process does, so a run that never reaches its first line still shows in `status`; the pid of the process started is
	 * the run's until the run writes its own.
	 */
	public static function start(repo: String, sha: String, cache: String, suite: Bool): Outcome {
		FileSystem.createDirectory(directory(cache));
		File.saveContent(recordOf(cache, sha, RUNNING), '${fileOf(cache, sha, LOG)}\n');
		remove(fileOf(cache, sha, PID));
		final pid: Int = launch(directory(cache), sha, repo, script -> argvOf(Lease.pooled(), script, repo, sha, cache, suite));
		keepFirst(fileOf(cache, sha, PID), pid);
		return Passed;
	}

	/**
	 * The land's first step: it does not start on a main whose whole suite ended red after an earlier land, and the whole suite
	 * of a commit whose run was lost is started again by `start` (a land that cannot start one only names it).
	 */
	public static function unsettled(cache: Null<String>, start: Null<PostLandStart>, repo: String, note: String -> Void): Outcome {
		if (cache == null) return Skipped('no battery');
		final underway: Array<String> = running(cache);
		if (underway.length > 0) note('whole suite not ended: ${underway.join(' ')} (`node bin/dev.js post-land status`)');
		for (sha in lost(cache)) {
			if (start == null) {
				note('whole suite LOST: $sha (`node bin/dev.js post-land status`)');
				continue;
			}
			final again: Outcome = start(repo, sha, cache, true);
			if (!again.match(Passed)) return again;
			note('whole suite of $sha was lost, runs again in the background (`node bin/dev.js post-land status`)');
		}
		final refused: Null<String> = refusal(cache);
		return refused == null ? Passed : Failed(refused);
	}

	/**
	 * The land's last step: when only an `impacted` suite ran under the lock, the whole suite of `head` is started beside the next
	 * land by `start`; a land whose battery ran every class has nothing left to start.
	 */
	public static function afterwards(
		start: Null<PostLandStart>, impacted: Bool, repo: String, head: String, cache: Null<String>, moved: Null<Array<String>>,
		note: String -> Void
	): Outcome {
		if (start == null || cache == null) return Skipped('no battery');
		final row: Outcome = hxcppRow(moved, () -> Passed);
		if (!impacted && row.match(Skipped(_))) return Skipped('the battery ran the whole suite and the land touched no src/');
		final sha: String = Battery.keyOf(repo, head) ?? head;
		final started: Outcome = start(repo, sha, cache, impacted);
		if (started.match(Passed))
			note(
				'${impacted ? 'whole suite' : 'hxcpp build'} of $sha runs in the background, no lock held (`node bin/dev.js post-land status`)'
			);
		return started;
	}

	/**
	 * Ends the record of a run: the `running` mark and the run's copy of the tool always go, and the log goes with a green run —
	 * a red run keeps it, since the `red` record names it.
	 */
	public static function settle(cache: String, sha: String, verdict: Outcome): Void {
		final unrun: Bool = verdict.match(NotRun(_));
		if (!unrun) remove(recordOf(cache, sha, RUNNING));
		remove(fileOf(cache, sha, PID));
		release(directory(cache), sha, unrun || verdict.match(Failed(_)));
		switch verdict {
			case Failed(why):
				File.saveContent(recordOf(cache, sha), '$why — ${fileOf(cache, sha, LOG)}\n');
			case _:
		}
	}

	/**
	 * What `body` answers over a checkout of `sha` in a worktree and a scratch directory of this run's own (`work`, `tree`),
	 * both removed after it; a body that throws, or a commit that cannot be checked out, answers `Failed` naming `who`.
	 */
	public static function inWorktree(repo: String, sha: String, who: String, body: (work: String, tree: String) -> Outcome): Outcome {
		final dirs: TmpLifecycle = TmpLifecycle.fromEnv();
		final work: String = dirs.claimAfterSweep(WORK_PREFIX, repo);
		final tree: String = Path.join([work, 'tree']);
		final verdict: Outcome = try {
			final added: Result = cmd('git -C $repo worktree add --detach $tree $sha').run();
			added.ok ? body(work, tree) : Failed('no tree of $sha: ${added.firstError()}');
		} catch (exception: haxe.Exception) {
			Failed('$who stopped: ${exception.message}');
		}
		if (FileSystem.exists(tree)) cmd('git -C $repo worktree remove --force $tree').run();
		dirs.discard(work, repo);
		return verdict;
	}

	/**
	 * Starts a run of this tool detached, its output in `<dir>/<sha>.log`, from a copy of the running script kept as
	 * `<dir>/<sha>.dev.js` (a rebuilt `bin/dev.js` cannot change a run in flight); `argvOf` answers the command line for that copy.
	 * `release` removes what this leaves. Answers the pid of the process started.
	 */
	public static function launch(dir: String, sha: String, repo: String, argvOf: String -> Array<String>): Int {
		FileSystem.createDirectory(dir);
		final script: String = fileIn(dir, sha, SCRIPT);
		File.copy(FileSystem.fullPath(js.Node.__filename), script);
		return detach(argvOf(script), repo, fileIn(dir, sha, LOG));
	}

	/** The command `command` behind the pool lease `mode` grants, of the share a heavy phase of a detached run asks for. */
	public static function leased(mode: LeaseMode, command: Command, label: String, ?history: LeaseHistory): Command {
		final ask: Ask = Branches.heavyAsk(Lease.HEAVY_MIN, Shard.DEFAULT_SHARDS, history, LeaseHistory.keyOf(label));
		ask.priority = 0;
		return Lease.take(mode, command, ask, label);
	}

	/**
	 * `command`, the whole lint, behind a lease of one process on the node engine's cpus (`Lease.NODE_CORES`). The lint is not one
	 * single-threaded process: its compiler-oracle builds fan out by the processes the lease hands it (`WF_THREADS`), so the lease
	 * caps that fan-out at one compile at a time. The lint
	 * is bounded from its grant by `PHASE_TIMEOUT_MS`: the driver's default bound for a leased job sits at what an honest whole lint takes.
	 */
	public static function lintLeased(mode: LeaseMode, command: Command, label: String): Command {
		return Lease.take(mode, command.timeout(PHASE_TIMEOUT_MS), LINT_ASK, label);
	}

	/** What `launch` left in `dir` for `sha`: the script copy always, the log unless `keepLog`. */
	public static function release(dir: String, sha: String, keepLog: Bool): Void {
		remove(fileIn(dir, sha, SCRIPT));
		if (!keepLog) remove(fileIn(dir, sha, LOG));
	}

	/** The file `<sha>.<suffix>` in `dir`. */
	public static function fileIn(dir: String, sha: String, suffix: String): String {
		return Path.join([dir, '$sha.$suffix']);
	}

	/**
	 * Why the report `recorded` is not the whole lint `truth` of its tree, or null when `lint-diff` finds them the same. `scope` is what
	 * the land re-linted (null or empty: nothing was carried); the findings of a rule it carried there (`LintScope.carriedRules`) are
	 * left out of both, since the land carried them unjudged.
	 */
	public static function snapshotRefusal(tree: String, recorded: String, truth: String, scope: Null<Array<String>>): Null<String> {
		final linted: Array<String> = scope ?? [];
		final dependent: Null<Array<String>> = linted.length == 0
			? []
			: LintScope.carriedRules(GateTree.shim(tree, tree, LintScope.RULE_LISTING).run().out);
		if (dependent == null) return 'the engine\'s rule listing printed no report, so the backstop cannot tell what the land carried';
		final old: String = judgedCopy(recorded, linted, dependent);
		final now: String = judgedCopy(truth, linted, dependent);
		final diff: Result = GateTree.shim(tree, tree, ['lint-diff', '--old', old, '--new', now]).run();
		for (copy in [old, now]) FileSystem.deleteFile(copy);
		return (diff.status ?? 2) > 1
			? 'lint-diff could not compare $recorded with the whole lint: ${diff.firstError()}'
			: LintScope.backstop(GateLint.moveOf(diff));
	}

	/**
	 * The whole lint of the landed tree, the truth of the landing's lint snapshot: a battery that re-linted only the files its change
	 * reaches (`LintScope`) carried the rest from its base, and a finding that moved elsewhere makes this run red. The truth replaces
	 * the snapshot either way, so the next landing compares with what the tree really holds.
	 */
	public static function wholeLint(repo: String, sha: String, cache: String, tree: String, mode: LeaseMode = Unpooled): Outcome {
		final lint: Result = lintLeased(
			mode,
			GateTree.shim(tree, tree, ['lint', '--format', 'json', '--all'].concat(LintScope.ROOTS)).under(['sh', '-c', LINT_START, 'sh']),
			'post-land-lint $sha'
		).run();
		final own: Null<Result> = afterStart(lint);
		if (own == null) return NotRun('the whole lint of $sha never started: ${endOf(lint)}');
		if (!lint.out.trim().startsWith('['))
			return Failed('the whole lint of $sha printed no report (${endOf(lint)}): ${own.firstError()}');
		final snapshot: String = Path.join([cache, '${Battery.keyOf(repo, sha) ?? sha}-anyparse.json']);
		final truth: String = '$snapshot.truth';
		File.saveContent(truth, lint.out);
		final refusal: Null<String> = FileSystem.exists(snapshot)
			? snapshotRefusal(tree, snapshot, truth, LintScope.ofImpact(tree, '$sha^', true))
			: null;
		FileSystem.rename(truth, snapshot);
		return refusal == null ? Passed : Failed(refusal);
	}

	/**
	 * The hxcpp row of a run: `build` when the land changed an engine input (or `changed` is null, git could not say), a skip
	 * otherwise. No gate or battery row compiles for hxcpp, so a break only the C++ compile reports survives until this runs.
	 */
	public static function hxcppRow(changed: Null<Array<String>>, build: () -> Outcome): Outcome {
		return changed != null && !changed.exists(GateTree.isEngineInput) ? Skipped('the land touched no src/') : build();
	}

	/**
	 * The full build of `tools/bench-hxcpp.hxml` in `tree`, Haxe and C++ compile both (neither `--no-output` nor
	 * `-D no-compilation` reaches the C++ errors), through a compile cache of the snapshot cache so a later run only recompiles what moved.
	 */
	public static function hxcppBuild(tree: String, cache: String, mode: LeaseMode, granted: Int -> Void): Outcome {
		final built: Result = hxcppCommand(tree, cache, mode).run();
		final text: String = built.out + built.err;
		Sys.println(text);
		final held: Null<Int> = hxcppGrantOf(text);
		if (mode.match(Own(_, _)) && held != null) granted(held);
		return built.ok ? Passed : Failed('the hxcpp build failed: ${built.firstError()}');
	}

	/**
	 * The hxcpp build of `tree` behind a lease of its own under `mode`, compiling on the threads its grant (`WF_THREADS`) names, else
	 * `Shard.DEFAULT_SHARDS`; it prints the grant first, as the one place the run reads what it held.
	 */
	public static function hxcppCommand(tree: String, cache: String, mode: LeaseMode): Command {
		final script: String = 'echo "$THREADS_MARK$${WF_THREADS:-}"; HXCPP_COMPILE_THREADS="$${WF_THREADS:-${Shard.DEFAULT_SHARDS}}" '
			+ 'exec haxe tools/bench-hxcpp.hxml';
		final build: Command = Command.of(['sh', '-c', script, 'sh'])
			.at(tree)
			.env('HXCPP_COMPILE_CACHE', Path.join([cache, HXCPP_CACHE]))
			.timeout(PHASE_TIMEOUT_MS);
		return Lease.take(mode, build, { min: Lease.HEAVY_MIN, max: Shard.DEFAULT_SHARDS, priority: 0 }, 'post-land-hxcpp');
	}

	/** The threads the hxcpp build's lease granted, as `hxcppCommand` prints them first in `text`; null when it printed none. */
	public static function hxcppGrantOf(text: String): Null<Int> {
		return THREADS_LINE.match(text) ? Std.parseInt(THREADS_LINE.matched(1)) : null;
	}

	/** Writes `pid` into `file` unless the run, faster than its starter, has already written its own. */
	public static function keepFirst(file: String, pid: Int): Void {
		js.Syntax.code(
			"(function (f, t) { try { require('fs').writeFileSync(f, t, { flag: 'wx' }); } catch (e) { } })({0}, {1})", file, '$pid\n'
		);
	}

	/** The commits of the records `<sha>.<state>` in `dir`, none when `dir` does not exist. */
	public static function recorded(dir: String, state: String = RUNNING): Array<String> {
		if (!FileSystem.exists(dir)) return [];
		final suffix: String = '.$state';
		return [ for (name in FileSystem.readDirectory(dir)) if (name.endsWith(suffix)) name.substr(0, name.length - suffix.length) ];
	}

	/** Deletes `path` when it exists. */
	public static function remove(path: String): Void {
		if (FileSystem.exists(path)) FileSystem.deleteFile(path);
	}

	/**
	 * The verdict of a whole-suite run from its whole-lint row `linted` (never `Failed` here) and its hxcpp row `compiled`: a red
	 * hxcpp build is red whatever the lint did, and a lint that never started leaves the run without a verdict rather than green.
	 */
	public static function runVerdict(linted: Outcome, compiled: Outcome): Outcome {
		return !compiled.match(Failed(_)) && linted.match(NotRun(_)) ? linted : compiled;
	}

	private static inline function recordOf(cache: String, sha: String, state: String = RED): String {
		return fileOf(cache, sha, state);
	}

	/** `argv` started in its own session with both output streams in `log`, so it outlives this process and holds none of its pipes. */
	private static function detach(argv: Array<String>, cwd: String, log: String): Int {
		final fd: Int = js.Syntax.code("require('fs').openSync({0}, 'w')", log);
		final child: js.node.child_process.ChildProcess = js.node.ChildProcess.spawn(
			argv[0], argv.slice(1), { cwd: cwd, detached: true, stdio: ['ignore', fd, fd] }
		);
		child.unref();
		js.Syntax.code("require('fs').closeSync({0})", fd);
		return child.pid;
	}

	/** Whether the process of the run of `sha` still exists: a run with no pid recorded has none. */
	private static function alive(cache: String, sha: String): Bool {
		final file: String = fileOf(cache, sha, PID);
		final pid: Null<Int> = FileSystem.exists(file) ? Std.parseInt(File.getContent(file)) : null;
		return pid != null && js.Syntax.code(
			"(function (p) { try { process.kill(p, 0); return true; } catch (e) { return e.code === 'EPERM'; } })({0})", pid
		);
	}

	private static function run(repo: String, sha: String, cache: String, suite: Bool): Int {
		FileSystem.createDirectory(directory(cache));
		File.saveContent(recordOf(cache, sha, RUNNING), '${fileOf(cache, sha, LOG)}\n');
		File.saveContent(fileOf(cache, sha, PID), '${js.Node.process.pid}\n');

		// the suite run holds no lease: its phases take theirs, and the caller's `WF_THREADS` it inherited is none of its own;
		// the hxcpp-only run is one phase under one lease
		final verdict: Outcome = if (suite) {
			CpuMeter.begin(fileOf(cache, sha, DetachedRow.METERS));
			final whole: Outcome = inWorktree(repo, sha, DIRECTORY, (work, tree) -> judge(repo, sha, cache, work, tree));
			CpuMeter.end();
			whole;
		} else {
			DetachedRow.run(
				cache, directory(cache), sha, DIRECTORY, HXCPP_ROW,
				() -> inWorktree(repo, sha, DIRECTORY, (work, tree) -> hxcppHeld(tree, cache))
			);
		};
		settle(cache, sha, verdict);
		switch verdict {
			case Failed(why):
				Sys.println('post-land: $sha RED — $why');
				return 1;
			case NotRun(why):
				Sys.println('post-land: $sha NOT RUN — $why (a later land runs it again, or `post-land clear $sha`)');
				return 1;
			case _:
				Sys.println('post-land: $sha green');
				return 0;
		}
	}

	private static function judge(repo: String, sha: String, cache: String, work: String, tree: String): Outcome {
		final mode: LeaseMode = phaseMode();
		final built: Outcome = timed(
			cache, BUILD_ROW, granted -> Binaries.compileWith(tree, Path.join([work, 'build.log']), [], mode, granted)
		);
		switch built {
			case Failed(why):
				return Failed('the build of $sha failed: $why');
			case _:
		}
		final ran: Outcome = timed(cache, SHARD_ROW, granted -> shardRun(repo, sha, cache, tree, mode, granted));
		if (ran.match(Failed(_))) return ran;
		final linted: Outcome = timed(cache, LINT_ROW, granted -> {
			final held: Null<Int> = Lease.threadsOf(mode, LINT_ASK);
			if (held != null) granted(held);
			return wholeLint(repo, sha, cache, tree, mode);
		});
		if (linted.match(Failed(_))) return linted;
		final compiled: Outcome = hxcppRow(
			Land.mergedPaths(tree), () -> timed(cache, HXCPP_ROW, granted -> hxcppBuild(tree, cache, mode, granted))
		);
		return runVerdict(linted, compiled);
	}

	/**
	 * The whole suite of `tree` as `dev shard`, behind a lease of its own that it sizes its shards by (`WF_THREADS`). A green run
	 * leaves its time on that many threads in the lease history of its label, which is what the next lease asks the pool with.
	 */
	private static function shardRun(
		repo: String, sha: String, cache: String, tree: String, mode: LeaseMode, granted: Int -> Void
	): Outcome {
		final history: LeaseHistory = LeaseHistory.under(cache);
		final label: String = 'post-land-shard $sha';
		final shard: Command = cmd('node bin/dev.js shard')
			.at(tree)
			.env('HXQ_BIN', Path.join([tree, 'bin/apq.js']))
			.timeout(SHARD_TIMEOUT_MS);
		final ran: Result = leased(mode, shard, label, history).run();
		final text: String = ran.out + ran.err;
		Sys.println(text);
		final counts: Null<Array<Int>> = countsOf(text);
		if (counts != null)
			File.saveContent(Path.join([cache, '${Battery.keyOf(repo, sha) ?? sha}-suite.txt']), '${counts[0]} ${counts[1]}\n');
		final span: Null<ShardSpan> = spanOf(text);
		if (span != null && mode.match(Own(_, _))) {
			granted(span.shards);
			if (ran.ok) history.record(LeaseHistory.keyOf(label), span.shards, span.ms);
		}
		return ran.ok ? Passed : Failed(text.split('\n').find(l -> l.startsWith('suite-shard: FAILED')) ?? ran.firstError());
	}

	private static function directory(cache: String): String {
		return Path.join([cache, DIRECTORY]);
	}

	private static function fileOf(cache: String, sha: String, suffix: String): String {
		return fileIn(directory(cache), sha, suffix);
	}

	/** A copy of the report file `report`, beside it, holding only what the backstop judges. */
	private static function judgedCopy(report: String, scope: Array<String>, dependent: Array<String>): String {
		final copy: String = '$report.judged';
		File.saveContent(copy, LintScope.judged(File.getContent(report), scope, dependent));
		return copy;
	}

	private static function hxcppProbe(repo: String, sha: String, cache: String): Int {
		final verdict: Outcome = inWorktree(repo, sha, DIRECTORY, (work, tree) -> hxcppHeld(tree, cache));
		switch verdict {
			case Failed(why):
				Sys.println('post-land: hxcpp $sha RED — $why');
				return 1;
			case Skipped(why):
				Sys.println('post-land: hxcpp $sha skipped — $why');
				return 0;
			case _:
				Sys.println('post-land: hxcpp $sha green');
				return 0;
		}
	}

	/** The hxcpp row of a run that holds a lease of its own, or whose caller does. */
	private static function hxcppHeld(tree: String, cache: String): Outcome {
		return hxcppRow(Land.mergedPaths(tree), () -> hxcppBuild(tree, cache, Lease.ofEnvironment(), _ -> {}));
	}

	/**
	 * `lint` with only the stderr text its own program wrote, after the lease wrapper's waiting text, or null when the start mark is
	 * not there: the lint never started. A line the process driver appends for a process left behind quotes that process's command
	 * line, which holds the mark too, so only the text before the first such line is searched.
	 */
	private static function afterStart(lint: Result): Null<Result> {
		final noted: EReg = ~/^orphan (?:left running|held output): /m;
		final head: String = noted.match(lint.err) ? lint.err.substr(0, noted.matchedPos().pos) : lint.err;
		final started: Int = head.indexOf(LINT_MARK);
		return started < 0
			? null
			: new Result(lint.command, {
				status: lint.status,
				out: lint.out,
				err: lint.err.substr(started + LINT_MARK.length),
				failure: lint.failure,
				overflowed: false
			});
	}

	/**
	 * How the command of `lint` ended, from its own status and `failure` alone: a lease wrapper that ended without granting printed
	 * only waiting text, whose holder list names other commands and says nothing of why it ended.
	 */
	private static function endOf(lint: Result): String {
		final status: String = lint.status == null ? 'ended by a signal' : 'exited ${lint.status}';
		return lint.failure == '' ? status : '$status, ${lint.failure}';
	}

}

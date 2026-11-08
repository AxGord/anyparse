package dev;

import anyparse.core.PoolLease;
import devkit.Args;
import devkit.Cmd.cmd;
import devkit.Command;
import devkit.Lease;
import devkit.Result;
import devkit.Summary.Outcome;
import devkit.TmpLifecycle;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * The one answer to "did the whole suite pass on a commit whose land ran only the classes its change reaches": `dev land`
 * starts `dev post-land run <sha>` once the land has passed, a process that outlives the land and its lock, takes a lease
 * of its own from the pool, checks the commit out into a worktree of its own, builds it and runs the whole suite
 * there and then the whole lint (the check of the lint snapshot a land carried from its base, `LintScope`). A green
 * run leaves nothing; a red one leaves `<sha>.red` in the snapshot cache, which the next land refuses on until
 * `dev post-land clear <sha>`. The run never holds the land lock, so it never delays the next land.
 */
@:nullSafety(Strict)
final class PostLand {

	public static inline final USAGE: String =
		'usage: dev post-land run <sha> [--repo <dir>] [--cache <dir>] | status [--cache <dir>] | clear (<sha>... | --all) [--cache <dir>]';

	/** The directory of the snapshot cache that holds the records and the run's own copy of `dev.js`. */
	private static inline final DIRECTORY: String = 'post-land';

	private static inline final RUNNING: String = 'running';
	private static inline final RED: String = 'red';
	private static inline final LOG: String = 'log';
	private static inline final PID: String = 'pid';
	private static inline final SCRIPT: String = 'dev.js';
	private static inline final WORK_PREFIX: String = 'apq-dev';
	private static inline final SHARD_TIMEOUT_MS: Int = 3 * 60 * 60 * 1000;

	/** The totals line `dev shard` ends its tally with. */
	private static final TOTALS: EReg = ~/--- suite-shard: \d+ classes \/ (\d+) tests \/ (\d+) assertions/;

	/** The pool's lease for the run: flexible, and behind the leases a land asks for. */
	private static final ASK: Ask = {
		min: Lease.HEAVY_MIN,
		max: Shard.DEFAULT_SHARDS,
		priority: 0
	};

	/** The commits whose whole suite ended red and were not cleared. */
	public static inline function red(cache: String): Array<String> {
		return recorded(cache, RED);
	}

	/** The commits whose whole suite was started, has not ended and whose process is still there. */
	public static function running(cache: String): Array<String> {
		return recorded(cache).filter(sha -> alive(cache, sha));
	}

	/**
	 * The commits whose run left a `running` record and no process: killed, slept through or reaped with the process group of
	 * the land that started it. Their whole suite never gave a verdict.
	 */
	public static function lost(cache: String): Array<String> {
		return recorded(cache).filter(sha -> !alive(cache, sha));
	}

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final cache: String = args.option('--cache') ?? Land.cacheDir(Sys.getEnv);
		final repo: Null<String> = args.option('--repo');
		final all: Bool = args.flag('--all');
		final words: Array<String> = args.rest(['<run|status|clear>']);
		final verb: String = words[0];
		final shas: Array<String> = words.slice(1);
		switch verb {
			case 'run':
				if (shas.length != 1) throw new UsageError('run takes one <sha>');
				return run(Repo.resolve(repo), shas[0], cache);
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

	/**
	 * The command line of the run for `sha`: a copy of `dev.js` the run owns (a later land rebuilds the shared one), under
	 * the pool lease `mode` grants it.
	 */
	public static function argvOf(mode: LeaseMode, script: String, repo: String, sha: String, cache: String): Array<String> {
		return leased(mode, ['node', script, DIRECTORY, 'run', sha, '--repo', repo, '--cache', cache], 'post-land $sha');
	}

	/**
	 * Start the whole-suite run of `sha` detached from this process and answer at once. The record `running` exists before
	 * the process does, so a run that never reaches its first line still shows in `status`; the pid of the process started is
	 * the run's until the run writes its own.
	 */
	public static function start(repo: String, sha: String, cache: String): Outcome {
		FileSystem.createDirectory(directory(cache));
		File.saveContent(recordOf(cache, sha, RUNNING), '${fileOf(cache, sha, LOG)}\n');
		remove(fileOf(cache, sha, PID));
		final pid: Int = launch(directory(cache), sha, repo, script -> argvOf(Lease.pooled(), script, repo, sha, cache));
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
			final again: Outcome = start(repo, sha, cache);
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
		start: Null<PostLandStart>, impacted: Bool, repo: String, head: String, cache: Null<String>, note: String -> Void
	): Outcome {
		if (start == null || cache == null || !impacted) return Skipped('the battery ran the whole suite');
		final sha: String = Battery.keyOf(repo, head) ?? head;
		final started: Outcome = start(repo, sha, cache);
		if (started.match(Passed)) note('whole suite of $sha runs in the background, no lock held (`node bin/dev.js post-land status`)');
		return started;
	}

	/**
	 * Ends the record of a run: the `running` mark and the run's copy of the tool always go, and the log goes with a green run —
	 * a red run keeps it, since the `red` record names it.
	 */
	public static function settle(cache: String, sha: String, verdict: Outcome): Void {
		remove(recordOf(cache, sha, RUNNING));
		remove(fileOf(cache, sha, PID));
		release(directory(cache), sha, verdict.match(Failed(_)));
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
	public static function inWorktree(repo: String, sha: String, who: String, body: (work:String, tree:String) -> Outcome): Outcome {
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

	/** The command `words` behind the pool lease `mode` grants, as a detached run of this tool asks for it. */
	public static function leased(mode: LeaseMode, words: Array<String>, label: String): Array<String> {
		return Lease.take(mode, Command.of(words), ASK, label).argv;
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
	 * the land re-linted (null or empty: nothing was carried); a scope-dependent rule's findings on those files are left out of both,
	 * since the land carried them unjudged.
	 */
	public static function snapshotRefusal(tree: String, recorded: String, truth: String, scope: Null<Array<String>>): Null<String> {
		final linted: Array<String> = scope ?? [];
		final dependent: Null<Array<String>> = linted.length == 0
			? []
			: LintScope.scopeDependent(GateTree.shim(tree, tree, LintScope.RULE_LISTING).run().out);
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
	public static function wholeLint(repo: String, sha: String, cache: String, tree: String): Outcome {
		final lint: Result = GateTree.shim(tree, tree, ['lint', '--format', 'json', '--all'].concat(LintScope.ROOTS)).run();
		if (!lint.out.trim().startsWith('[')) return Failed('the whole lint of $sha printed no report: ${lint.firstError()}');
		final snapshot: String = Path.join([cache, '${Battery.keyOf(repo, sha) ?? sha}-anyparse.json']);
		final truth: String = '$snapshot.truth';
		File.saveContent(truth, lint.out);
		final refusal: Null<String> = FileSystem.exists(snapshot)
			? snapshotRefusal(tree, snapshot, truth, LintScope.ofImpact(tree, '$sha^', true))
			: null;
		FileSystem.rename(truth, snapshot);
		return refusal == null ? Passed : Failed(refusal);
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
		return pid != null
			&& js.Syntax.code(
				"(function (p) { try { process.kill(p, 0); return true; } catch (e) { return e.code === 'EPERM'; } })({0})", pid
			);
	}

	/** Writes `pid` into `file` unless the run, faster than its starter, has already written its own. */
	private static function keepFirst(file: String, pid: Int): Void {
		js.Syntax.code(
			"(function (f, t) { try { require('fs').writeFileSync(f, t, { flag: 'wx' }); } catch (e) { } })({0}, {1})", file, '$pid\n'
		);
	}

	private static function run(repo: String, sha: String, cache: String): Int {
		FileSystem.createDirectory(directory(cache));
		File.saveContent(recordOf(cache, sha, RUNNING), '${fileOf(cache, sha, LOG)}\n');
		File.saveContent(fileOf(cache, sha, PID), '${js.Node.process.pid}\n');
		final verdict: Outcome = inWorktree(repo, sha, DIRECTORY, (work, tree) -> judge(repo, sha, cache, work, tree));
		settle(cache, sha, verdict);
		switch verdict {
			case Failed(why):
				Sys.println('post-land: $sha RED — $why');
				return 1;
			case _:
				Sys.println('post-land: $sha green');
				return 0;
		}
	}

	private static function judge(repo: String, sha: String, cache: String, work: String, tree: String): Outcome {

		switch Binaries.compileWith(tree, Path.join([work, 'build.log']), [], Lease.ofEnvironment()) {
			case Failed(why):
				return Failed('the build of $sha failed: $why');
			case _:
		}
		final shards: Int = PoolLease.threads() ?? Shard.DEFAULT_SHARDS;
		final ran: Result = cmd('node bin/dev.js shard -n $shards')
			.at(tree)
			.env('HXQ_BIN', Path.join([tree, 'bin/apq.js']))
			.timeout(SHARD_TIMEOUT_MS)
			.run();
		final text: String = ran.out + ran.err;
		Sys.println(text);
		final counts: Null<Array<Int>> = countsOf(text);
		if (counts != null)
			File.saveContent(Path.join([cache, '${Battery.keyOf(repo, sha) ?? sha}-suite.txt']), '${counts[0]} ${counts[1]}\n');
		return ran.ok
			? wholeLint(repo, sha, cache, tree)
			: Failed(text.split('\n').find(l -> l.startsWith('suite-shard: FAILED')) ?? ran.firstError());
	}

	private static function directory(cache: String): String {
		return Path.join([cache, DIRECTORY]);
	}

	private static function recorded(cache: String, state: String = RUNNING): Array<String> {
		final dir: String = directory(cache);
		if (!FileSystem.exists(dir)) return [];
		final suffix: String = '.$state';
		return [
			for (name in FileSystem.readDirectory(dir)) if (name.endsWith(suffix)) name.substr(0, name.length - suffix.length)
		];
	}

	private static function fileOf(cache: String, sha: String, suffix: String): String {
		return fileIn(directory(cache), sha, suffix);
	}

	private static function remove(path: String): Void {
		if (FileSystem.exists(path)) FileSystem.deleteFile(path);
	}

	/** A copy of the report file `report`, beside it, holding only what the backstop judges. */
	private static function judgedCopy(report: String, scope: Array<String>, dependent: Array<String>): String {
		final copy: String = '$report.judged';
		File.saveContent(copy, LintScope.judged(File.getContent(report), scope, dependent));
		return copy;
	}

}

/** The start of the whole suite of a landed commit: the tree, the commit and the snapshot cache. */
typedef PostLandStart = (tree:String, sha:String, cache:String) -> Outcome;

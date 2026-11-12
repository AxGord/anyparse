package dev;

import dev.ArmRegistry.ArmRecord;
import devkit.Args;
import devkit.Cmd.cmd;
import devkit.Command;
import devkit.Excerpt;
import devkit.Lease;
import devkit.Result;
import devkit.Summary.Outcome;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * The one answer to "which arms of the whole registry no longer kill on a landed commit": on every `EVERY`th landing,
 * `dev land` starts `dev arm-sweep run <sha>`, a process that outlives the land and its lock, takes a lease of its own from
 * the pool below every slice's priority, checks the commit out into a worktree of its own, builds it, runs every arm of the
 * registry there and writes `<cache>/arm-sweep/<sha>.verdict.txt`: the count of arms killed and one line per arm that did
 * not hold, with its type and killer. A rotted arm is not the landing's fault: the sweep never refuses a land, and the parent
 * queues the repairs from the verdict.
 */
@:nullSafety(Strict)
final class ArmSweep {

	public static inline final USAGE: String =
		'usage: dev arm-sweep run <sha> [--repo <dir>] [--cache <dir>] | status [--cache <dir>] | verdict <log> [--repo <dir>]';

	/**
	 * The landings from one sweep to the next: rare enough that a sweep of the whole registry ends long before the next is
	 * due, frequent enough that an arm rotted since the last sweep is found before many slices trip on it.
	 */
	public static inline final EVERY: Int = 30;

	/** The verdict file of a sweep, beside its records. */
	public static final VERDICT: String = 'verdict.txt';

	/** The record of a sweep that could not run: no tree, no build, or no track reported. */
	public static final FAILED: String = 'failed';

	private static inline final SWEEP_TIMEOUT_MS: Int = 12 * 60 * 60 * 1000;
	private static final DIRECTORY: String = 'arm-sweep';
	private static final RUNNING: String = 'running';
	private static final PID: String = 'pid';
	private static final LOG: String = 'log';

	/** The filter column of a track row: the test classes whose pins name the arm as their killer. */
	private static final KILLER: EReg = ~/ filter=(\S+)/;

	/**
	 * A small lease queued below every other: the pool hands it out only when no gate, land or post-land run waits, and
	 * while it is held it takes few of the pool's threads from the leases that come after it.
	 */
	private static final ASK: Ask = { min: 1, max: 2, priority: -1 };

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final repo: Null<String> = args.option('--repo');
		final cache: String = args.option('--cache') ?? Land.cacheDir(Sys.getEnv);
		final words: Array<String> = args.rest(['<run|status>']);
		return switch words {
			case ['run', sha]: run(Repo.resolve(repo), sha, cache);
			case ['status']:
				for (line in statusLines(directory(cache))) Sys.println(line);
				0;
			case ['verdict', log]:
				Sys.print(verdict(File.getContent(log), ArmRegistry.read(Path.join([Repo.resolve(repo), ArmRegistry.DIRECTORY]))));
				0;
			case _: throw new UsageError('`run <sha>`, `status` or `verdict <log>`');
		};
	}

	/** Whether landing number `landing` is one a sweep follows: every `every`th; none when the land kept no count. */
	public static function due(landing: Null<Int>, every: Int): Bool {
		return landing != null && every > 0 && landing % every == 0;
	}

	/**
	 * The land's step after the warm: on a due `landing` it starts the sweep of the landed `head` through `start`, and it never
	 * fails the land — a sweep that cannot start is a note, not a verdict.
	 */
	public static function afterwards(
		start: Null<SweepStart>, landing: Null<Int>, every: Int, repo: String, head: String, note: String -> Void
	): Outcome {
		if (start == null) return Skipped('no arm sweep requested');
		if (!due(landing, every)) return Skipped('not a landing an arm sweep follows');
		return try {
			switch start(repo, head) {
				case Passed:
					note('arm sweep of $head runs in the background (`node bin/dev.js arm-sweep status`)');
					Passed;
				case Failed(why): Skipped('arm sweep not started: $why');
				case other: other;
			}
		} catch (exception: haxe.Exception) {
			Skipped('arm sweep not started: ${exception.message}');
		}
	}

	/** Start the sweep of `sha` detached from this process and answer at once; a sweep still running is not started again. */
	public static function start(repo: String, sha: String, cache: String): Outcome {
		final dir: String = directory(cache);
		return begin(dir, sha, () -> PostLand.launch(dir, sha, repo, script -> argvOf(Lease.pooled(), script, repo, sha, cache)));
	}

	/**
	 * The start of a sweep of `sha` whose records live in `dir`, by `launch`, which answers the pid it started. Refused while
	 * the process of an earlier sweep is alive; the record `running` exists before the process does.
	 */
	public static function begin(dir: String, sha: String, launch: () -> Int): Outcome {
		final busy: Null<String> = underway(dir);
		if (busy != null) return Skipped('the arm sweep of $busy is still running');
		FileSystem.createDirectory(dir);
		File.saveContent(PostLand.fileIn(dir, sha, RUNNING), '${PostLand.fileIn(dir, sha, LOG)}\n');
		PostLand.remove(PostLand.fileIn(dir, sha, PID));
		final pid: Int = launch();
		PostLand.keepFirst(PostLand.fileIn(dir, sha, PID), pid);
		return Passed;
	}

	/**
	 * The commit of the sweep recorded in `dir` whose process is alive, or null. A record whose process is gone is a sweep
	 * that will never end: it is removed, so it holds no later start.
	 */
	public static function underway(dir: String): Null<String> {
		for (sha in PostLand.recorded(dir, RUNNING)) {
			final file: String = PostLand.fileIn(dir, sha, PID);
			final pid: Null<Int> = FileSystem.exists(file) ? Std.parseInt(File.getContent(file).trim()) : null;
			if (pid != null && MutationSlot.alive(pid)) return sha;
			PostLand.remove(PostLand.fileIn(dir, sha, RUNNING));
			PostLand.remove(file);
		}
		return null;
	}

	/** The command line of the detached run: this tool's own copy `script`, behind the low-priority pool lease `mode` grants. */
	public static function argvOf(mode: LeaseMode, script: String, repo: String, sha: String, cache: String): Array<String> {
		final words: Array<String> = ['node', script, DIRECTORY, 'run', sha, '--repo', repo, '--cache', cache];
		return Lease.take(mode, Command.of(words), ASK, 'arm-sweep $sha').argv;
	}

	/**
	 * The verdict of a sweep whose `dev mutation-arm` printed `log`, over the registry `records`: the count of arms killed, then
	 * one line per arm that did not hold (`unheld`).
	 */
	public static function verdict(log: String, records: Array<ArmRecord>): String {
		final lines: Array<String> = ['KILLED ${GateExcerpt.killedNames(log).length}'].concat(unheld(log, records));
		return lines.map(line -> '$line\n').join('');
	}

	/**
	 * One line per track row of `log` whose arm did not hold — `<VERDICT> <name> type=<type> killer=<classes>` — the type read
	 * from the arm's record in `records`, the killer from the row; `-` for either when neither says.
	 */
	public static function unheld(log: String, records: Array<ArmRecord>): Array<String> {
		final types: Map<String, String> = [];
		for (record in records) {
			final type: Null<String> = ArmHeadParser.parse(record.text).type;
			if (type != null) types[record.key] = type;
		}
		return [
			for (row in GateExcerpt.armRows(log)) {
				final killer: String = KILLER.match(row.line) ? KILLER.matched(1) : '-';
				'${row.verdict} ${row.name} type=${types[row.name] ?? '-'} killer=$killer';
			}
		];
	}

	/**
	 * Why `dev mutation-arm`, which ended with `status` (null when it timed out or a signal killed it; `failure` says which) and
	 * printed `log`, gives no verdict over the registry `records`, or null when it does. A run cut short prints a part of its
	 * rows, and an arm with no row would read as one that held, so every arm of `records` must have a row.
	 */
	public static function refusal(status: Null<Int>, failure: String, log: String, records: Array<ArmRecord>): Null<String> {
		if (status == null) return 'dev mutation-arm did not finish: $failure';
		final reported: Map<String, Bool> = [
			for (name in GateExcerpt.killedNames(log).concat(GateExcerpt.armRows(log).map(row -> row.name))) name => true
		];
		final missing: Int = records.filter(record -> !reported.exists(record.key)).length;
		return missing == 0
			? null
			: 'dev mutation-arm reported ${records.length - missing} of ${records.length} arms: ${Excerpt.errors(log).join(' ')}';
	}

	/** One line per sweep recorded in `dir`: the one running, each verdict written, each sweep that could not run. */
	public static function statusLines(dir: String): Array<String> {
		final failed: Array<String> = PostLand.recorded(dir, FAILED);
		final lines: Array<String> = PostLand.recorded(dir, RUNNING)
			.map(sha -> 'arm-sweep: $sha running')
			.concat(PostLand.recorded(dir, VERDICT).map(sha -> 'arm-sweep: $sha verdict ${PostLand.fileIn(dir, sha, VERDICT)}'))
			.concat(failed.map(sha -> 'arm-sweep: $sha did not run — ${File.getContent(PostLand.fileIn(dir, sha, FAILED)).trim()}'));
		return lines.length == 0 ? ['arm-sweep: no record'] : lines;
	}

	private static function run(repo: String, sha: String, cache: String): Int {
		final dir: String = directory(cache);
		FileSystem.createDirectory(dir);
		File.saveContent(PostLand.fileIn(dir, sha, RUNNING), '${PostLand.fileIn(dir, sha, LOG)}\n');
		File.saveContent(PostLand.fileIn(dir, sha, PID), '${js.Node.process.pid}\n');
		PostLand.remove(PostLand.fileIn(dir, sha, FAILED));
		final ended: Outcome = PostLand.inWorktree(
			repo, sha, DIRECTORY, (work, tree) -> sweep(sha, work, tree, PostLand.fileIn(dir, sha, VERDICT))
		);
		PostLand.remove(PostLand.fileIn(dir, sha, RUNNING));
		PostLand.remove(PostLand.fileIn(dir, sha, PID));
		// the log stays whatever the verdict: a row of the verdict names an arm, the log holds why it did not hold
		PostLand.release(dir, sha, true);
		return switch ended {
			case Failed(why):
				File.saveContent(PostLand.fileIn(dir, sha, FAILED), '$why\n');
				Sys.println('arm-sweep: $sha did not run — $why');
				1;
			case _:
				Sys.println('arm-sweep: $sha verdict ${PostLand.fileIn(dir, sha, VERDICT)}');
				0;
		};
	}

	/** Builds `tree` and runs every arm of its registry there; the verdict goes to `verdictFile`, survivors are no failure. */
	private static function sweep(sha: String, work: String, tree: String, verdictFile: String): Outcome {
		switch Binaries.compileWith(tree, Path.join([work, 'build.log']), [], Lease.ofEnvironment()) {
			case Failed(why):
				return Failed('the build of $sha failed: $why');
			case _:
		}
		final ran: Result = cmd('node bin/dev.js mutation-arm --all --fast')
			.at(tree)
			.env('HXQ_BIN', Path.join([tree, 'bin/apq.js']))
			.timeout(SWEEP_TIMEOUT_MS)
			.run();
		final log: String = ran.out + ran.err;
		Sys.println(log);
		final records: Array<ArmRecord> = ArmRegistry.read(Path.join([tree, ArmRegistry.DIRECTORY]));
		final refused: Null<String> = refusal(ran.status, ran.failure, log, records);
		if (refused != null) return Failed(refused);
		File.saveContent(verdictFile, verdict(log, records));
		return Passed;
	}

	private static function directory(cache: String): String {
		return Path.join([cache, DIRECTORY]);
	}

}

/** Starts the arm sweep of a landed commit in `repo`. */
typedef SweepStart = (repo:String, sha:String) -> Outcome;

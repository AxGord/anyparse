package dev;

import anyparse.proc.PendingRuns;
import anyparse.proc.Sleep;
import devkit.Command;
import devkit.Result;
import devkit.TempDir;
import haxe.Exception;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * The one answer to "how does a process that is not `dev land` hold the land's lock around its own work": `dev land` runs
 * under the workflow's `anyparse-land` pool lock for the whole landing, so main moves only under it; a commit on main made
 * inside `hold` waits for a landing in flight and never moves main between a landing's `open` and `advance`. The lock is
 * the pool's own (`wf-run --lock`), never a second one.
 */
@:nullSafety(Strict)
final class LandLock {

	/** How long `hold` waits for a landing, in seconds: the longest a landing may run. */
	public static inline final DEFAULT_WAIT: Int = 5400;

	/** The exit of `wf-run` when the lock was not free within its wait (`EX_TEMPFAIL`). */
	public static inline final BUSY: Int = 75;

	/** The pool lock every landing runs under. */
	public static final NAME: String = 'anyparse-land';

	/** The seconds the holder may outlive the wait: the work that runs under the lock is short. */
	private static inline final GRACE: Int = 300;

	private static inline final POLL_MS: Int = 100;

	/** The wait after which `hold` says it is waiting. */
	private static inline final SAY_AFTER_MS: Int = 1000;

	private static inline final MS_PER_SECOND: Int = 1000;

	/** The pool's command under the workflow plugin's root. */
	private static final WF_RUN: String = 'scripts/wf-run';

	/** The holder: marks the grant in `$1`, then keeps the lock until `$2` appears. */
	private static final HOLDER: String = ': > "$1"; while [ ! -e "$2" ]; do sleep 0.1; done';

	/**
	 * `work`, run while this process holds the `anyparse-land` lock through the `wf-run` at `wfRun`. Waits at most
	 * `waitSeconds` for a landing to release it and says so through `say` once the wait shows; throws when the lock is not
	 * granted, and has released it whatever `work` does. The holder is tethered to this process, so a process killed
	 * outright releases the lock too.
	 */
	public static function hold<T>(wfRun: String, waitSeconds: Int, label: String, say: String -> Void, work: () -> T): T {
		return TempDir.with(dir -> {
			final granted: String = dir.file('granted');
			final release: String = dir.file('release');
			final holder: Command = Command.of([
				wfRun,
				'--lock',
				NAME,
				'--wait-timeout',
				'$waitSeconds',
				'--label',
				label,
				'--',
				'sh',
				'-c',
				HOLDER,
				'sh',
				granted,
				release
			])
				.timeout((waitSeconds + GRACE) * MS_PER_SECOND)
				.tethered();
			final batch: PendingRuns = holder.background();
			final began: Float = Date.now().getTime();
			var told: Bool = false;
			while (!FileSystem.exists(granted)) {
				if (!batch.running()) {
					final ended: Result = holder.answer(batch);
					throw new Exception(
						ended.status == BUSY
							? 'a landing holds the $NAME lock for more than $waitSeconds s'
							: 'the $NAME lock was not granted: ${ended.firstError()}'
					);
				}
				if (!told && Date.now().getTime() - began > SAY_AFTER_MS) {
					say('waiting for the $NAME lock (up to $waitSeconds s): a landing holds it');
					told = true;
				}
				Sleep.pause(POLL_MS);
			}
			if (told) say('the $NAME lock is granted after ${Math.round((Date.now().getTime() - began) / MS_PER_SECOND)} s');
			final box: Array<T> = [];
			var failure: Null<Exception> = null;
			try
				box.push(work())
			catch (exception: Exception)
				failure = exception;
			File.saveContent(release, '');
			holder.answer(batch);
			if (failure != null) throw failure;
			return box[0];
		});
	}

	/**
	 * The `wf-run` this process can take the lock through: the one under the plugin root a workflow exec names (`root`), else
	 * the newest installed one under `home`'s plugin cache, else null. Every `wf-run` reaches the same machine-wide pool.
	 */
	public static function locate(root: Null<String>, home: Null<String>): Null<String> {
		if (root != null && root != '') {
			final own: String = Path.join([root, WF_RUN]);
			if (FileSystem.exists(own)) return own;
		}
		if (home == null) return null;
		final cache: String = Path.join([home, '.claude', 'plugins', 'cache']);
		var best: Null<String> = null;
		var bestVersion: Array<Int> = [];
		for (market in children(cache)) {
			final versions: String = Path.join([cache, market, 'workflow']);
			for (version in children(versions)) {
				final candidate: String = Path.join([versions, version, WF_RUN]);
				final number: Array<Int> = versionOf(version);
				if (!FileSystem.exists(candidate) || (best != null && !newer(number, bestVersion))) continue;
				best = candidate;
				bestVersion = number;
			}
		}
		return best;
	}

	/** The dot-separated numbers of a version directory name; a part that is no number reads as 0. */
	public static function versionOf(name: String): Array<Int> {
		return name.split('.').map(part -> Std.parseInt(part) ?? 0);
	}

	/** Whether version `a` is later than `b`, numbers compared part by part. */
	public static function newer(a: Array<Int>, b: Array<Int>): Bool {
		for (i in 0...Std.int(Math.max(a.length, b.length))) {
			final left: Int = a[i] ?? 0;
			final right: Int = b[i] ?? 0;
			if (left != right) return left > right;
		}
		return false;
	}

	private static function children(dir: String): Array<String> {
		return FileSystem.exists(dir) && FileSystem.isDirectory(dir) ? FileSystem.readDirectory(dir) : [];
	}

}

package dev;

import anyparse.proc.Sleep;
import devkit.Summary.Outcome;
import haxe.Exception;
import haxe.Timer;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/** A reading of the base, or why a gate has none. */
enum BaseGot<T> {
	Got(value: T);
	NotGot(why: String);
}

/**
 * The one answer to "how does a gate row wait for a reading of the base that a branch of its own measures beside it": the
 * gate announces the branch in its logs before the branches start (`announce`); the branch leaves its reading or why there is
 * none, and only then lifts the announcement (`settle`); a row that asks while it stands waits for it (`read`) instead of
 * measuring the base a second time, and a row asking after a failed branch is told the same why. One instance per kind of
 * base reading (`BaseSuite`, `BaseLint`), each with its own markers and its own cache shared by every worktree on this machine.
 */
@:nullSafety(Strict)
final class BaseBranch {

	private static inline final MS_PER_SECOND: Float = 1000;
	private static inline final POLL_MS: Int = 1000;

	/** The gate row of the branch; it is no line of the gate's table. */
	public final row: String;

	/** The announcement of a branch still to leave its reading: the run's id; lifted when the branch has left it or why not. */
	public final pendingFile: String;

	/** Why the branch left no reading, when it left none. */
	public final unreadFile: String;

	/** The environment variable that names the shared cache instead of `_cacheName` under the scratch root. */
	private final _cacheVar: String;

	private final _cacheName: String;

	public function new(row: String, pendingFile: String, unreadFile: String, cacheVar: String, cacheName: String) {
		this.row = row;
		this.pendingFile = pendingFile;
		this.unreadFile = unreadFile;
		_cacheVar = cacheVar;
		_cacheName = cacheName;
	}

	/** The cache the readings are kept in, one entry per stamp, for every gate on this machine. */
	public function cache(): String {
		return Sys.getEnv(_cacheVar) ?? Path.join([anyparse.core.TempScratch.root(), _cacheName]);
	}

	/** Whether this run's branch is still to leave its reading: a reading is awaited then, never measured a second time beside it. */
	public function pending(gate: GateTree): Bool {
		final marker: String = gate.log(pendingFile);
		return FileSystem.exists(marker) && File.getContent(marker) == gate.options.run;
	}

	/** Lift what an earlier run left — its announcement and its why — before this run decides whether it needs the branch. */
	public function reset(gate: GateTree): Void {
		for (name in [unreadFile, pendingFile]) {
			final file: String = gate.log(name);
			if (FileSystem.exists(file)) FileSystem.deleteFile(file);
		}
	}

	/** Announce this run's branch: from now on a row asking for the reading waits for it. */
	public function announce(gate: GateTree): Void {
		File.saveContent(gate.log(pendingFile), gate.options.run);
	}

	/**
	 * The branch's row: `measure` (null when the reading is left, else why not) run, why it failed or threw left in the logs,
	 * and only then the announcement lifted, so a row waiting on it never sees the marker gone before the outcome is written.
	 */
	public function settle(gate: GateTree, measure: () -> Null<String>): Outcome {
		final why: Null<String> = try {
			measure();
		} catch (exception: Exception) {
			GateTree.clip(exception.message);
		};
		if (why != null) unread(gate, why);
		final marker: String = gate.log(pendingFile);
		if (FileSystem.exists(marker)) FileSystem.deleteFile(marker);
		return why == null ? Passed : Failed(why);
	}

	/**
	 * The reading for a row: `kept()` when it stands, else why this run found none, else — while the branch is announced — what
	 * it leaves once it lifts the announcement, else a measurement of the row's own (`measure`, as `settle` runs it); `missing`
	 * is the why of a branch that ended and left neither.
	 */
	public function read<T>(gate: GateTree, kept: () -> Null<T>, measure: () -> Null<String>, missing: String): BaseGot<T> {
		final held: Null<T> = kept();
		if (held != null) return Got(held);
		final failed: Null<String> = unreadWhy(gate);
		if (failed != null) return NotGot(failed);
		if (pending(gate)) {
			final deadline: Float = Timer.stamp() + BranchWatch.idleOf([row]) / MS_PER_SECOND;
			while (pending(gate) && Timer.stamp() < deadline) Sleep.pause(POLL_MS);
		} else {
			final why: Null<String> = measure();
			if (why != null) return NotGot(unread(gate, why));
		}
		final left: Null<T> = kept();
		return left != null ? Got(left) : NotGot(unreadWhy(gate) ?? missing);
	}

	/** Why this run found no reading, or null while none has failed: a second row never measures it again. */
	public function unreadWhy(gate: GateTree): Null<String> {
		final file: String = gate.log(unreadFile);
		return FileSystem.exists(file) ? File.getContent(file) : null;
	}

	/** `why`, left in the gate's logs for the rows of this run that ask next. */
	public function unread(gate: GateTree, why: String): String {
		File.saveContent(gate.log(unreadFile), why);
		return why;
	}

}

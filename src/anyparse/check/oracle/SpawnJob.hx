package anyparse.check.oracle;

import anyparse.grammar.json.JValue;

/**
 * One process `HaxeSpawn.runAll` runs: `haxe <args>`, or the `shell` command line when set, in `cwd` (the process cwd
 * when null), killed after `timeout` ms when that is positive.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef SpawnJob = {
	var args: Array<String>;
	var ?cwd: String;

	/** The program `args` are handed to, as an argument vector with no shell in between; `haxe` when absent. */
	var ?cmd: String;

	/** Variables set over this process's environment for the job alone. */
	var ?env: JValue;

	/**
	 * A file whose bytes are the job's standard input — a file, never a pipe (`docs/decisions.md`, "F1"); none when absent,
	 * and none for a `tethered` job, whose standard input is its tether.
	 */
	var ?stdin: String;

	var ?shell: String;
	var ?timeout: Int;

	/** Where the driver writes the job's process group leader (pid, then its start time) once it started. */
	var ?groupFile: String;

	/**
	 * The job never outlives the driver that started it, however the driver ends (`HaxeSpawn.TETHER`) — for a job that
	 * never ends by itself, a compilation server.
	 */
	var ?tethered: Bool;

	/**
	 * What the job's process group still runs when the job exits is named in the job's stderr and killed (`PARALLEL_DRIVER`),
	 * so nothing a job started outlives its run.
	 */
	var ?reap: Bool;

	/** Milliseconds without a byte on either stream or a change of `progress` after which the job is killed; 0 or absent is no limit. */
	var ?idle: Int;

	/** A file the job rewrites as it moves on: its modification counts as progress, and its text names where a stalled job stood. */
	var ?progress: String;

	/**
	 * The `idle` clock starts when `progress` first changes, not when the job starts: a job that queues for a lease before it
	 * runs is not silent, it has not begun.
	 */
	var ?awaitProgress: Bool;
}

package devkit;

import anyparse.proc.ProcessSpawn;
import anyparse.proc.SpawnJob;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * The one answer to "how much cpu did the processes a tool run started use, between two moments of it": every process the run
 * starts through `Command` or `Pool` is put under time(1), and `reading` is the cpu seconds of those that have ended. A step reads
 * it before and after, so its cpu is the difference. One meter is active per tool process (`begin` … `end`); a process that already
 * runs under time(1) (a branch, `Branches.metered`) is left to that reading. Only macOS's time(1) has `-l`: elsewhere nothing is
 * wrapped and `reading` is null.
 */
@:nullSafety(Strict)
final class CpuMeter {

	/** The meter the running tool has begun, which `wrap` and `reading` answer for; null outside a metered run. */
	private static var _active: Null<CpuMeter> = null;

	/** The usage files of the processes started and not yet read. */
	private final _pending: Array<String> = [];

	private final _dir: String;
	private final _program: Null<String>;
	private final _outer: Null<CpuMeter>;

	private var _used: Float = 0;

	/** How many usage files have been read: with the pending ones, the count of files named so far. */
	private var _read: Int = 0;

	private function new(dir: String, program: Null<String>, outer: Null<CpuMeter>) {
		_dir = dir;
		_program = program;
		_outer = outer;
	}

	private inline function program(): Null<String> {
		return _program;
	}

	private function usageFile(): String {
		final file: String = Path.join([_dir, '${_read + _pending.length}.time']);
		_pending.push(file);
		return file;
	}

	/** The cpu of every process whose usage file has appeared, read once and removed; a file time(1) left unreadable counts nothing. */
	private function collect(): Void {
		for (file in _pending.copy()) {
			// time(1) opens its file when the process starts and fills it at the end: an empty one is a process still running
			final used: Null<Float> = FileSystem.exists(file) ? Branches.cpuSeconds(File.getContent(file)) : null;
			if (used == null) continue;
			_used += used;
			FileSystem.deleteFile(file);
			_pending.remove(file);
			_read++;
		}
	}

	/**
	 * Start metering under directory `dir`, which holds the usage files until `end`; `program` is the time(1) to use, by default
	 * the system's where it reports a process tree's cpu. A meter begun inside another one takes over until it ends.
	 */
	public static function begin(dir: String, ?program: String): Void {
		final timer: Null<String> = program ?? (Sys.systemName() == 'Mac' && FileSystem.exists(Branches.TIME) ? Branches.TIME : null);
		if (timer != null) {
			if (FileSystem.exists(dir))
				clear(dir);
			else
				FileSystem.createDirectory(dir);
		}
		_active = new CpuMeter(dir, timer, _active);
	}

	/** Stop the active meter: its usage files go, and the meter begun before it (if any) is the active one again. */
	public static function end(): Void {
		final meter: Null<CpuMeter> = _active;
		if (meter == null) return;
		if (meter._program != null) FileSystem.deleteDirectory(meter._dir);
		_active = meter._outer;
	}

	/**
	 * The cpu seconds the processes started since `begin` used, of those that have ended; null when no meter is active or
	 * this platform has none to wrap with. A process still running counts in a later reading.
	 */
	public static function reading(): Null<Float> {
		final meter: Null<CpuMeter> = _active;
		if (meter == null || meter._program == null) return null;
		meter.collect();
		return meter._used;
	}

	/**
	 * `job` run under time(1), its usage left in a file of the active meter's directory: the job itself, changed in place, so a
	 * short program keeps the bound it would have had. A job that is no program of its own (a shell line), one the meter cannot
	 * wrap, or one that already runs under time(1) is returned as it is.
	 */
	public static function wrap(job: SpawnJob): SpawnJob {
		final meter: Null<CpuMeter> = _active;
		final program: Null<String> = meter?.program();
		final cmd: Null<String> = job.cmd;
		if (meter == null || program == null || cmd == null || job.shell != null) return job;
		if (cmd == Branches.TIME || job.args.contains(Branches.TIME)) return job;
		final bound: Int = ProcessSpawn.boundOf(job);
		final file: String = meter.usageFile();
		final prefix: Array<String> = ['-l', '-o', file, cmd];
		job.args = prefix.concat(job.args);
		job.cmd = program;
		if (bound > 0 && (job.timeout ?? 0) <= 0) job.timeout = bound;
		return job;
	}

	/** What an earlier run, or this one's processes, left in `dir`, removed: the meter owns its directory. */
	private static function clear(dir: String): Void {
		for (name in FileSystem.readDirectory(dir)) FileSystem.deleteFile(Path.join([dir, name]));
	}

}

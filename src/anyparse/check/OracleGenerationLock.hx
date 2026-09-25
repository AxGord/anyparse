package anyparse.check;

import haxe.io.Path;

using StringTools;

/**
 * The reader/writer lock that guards one `compilerOracle` generation across `apq` processes (`OracleGeneration`).
 *
 * The lock is a directory beside the generation's record. A SHARED hold is a `readers/<pid>` file carrying the
 * holder's start time; readers never wait for each other. The EXCLUSIVE hold is the `writer` directory, created
 * atomically, with an `owner` file (pid, start time, when) written whole by a rename; it waits until no OTHER live run
 * holds the lock shared, and a waiting writer holds new readers off. A holder is its pid AND the start time `ps`
 * reports, so a pid the system reused reads as a different process. A dead holder's exclusive hold is taken over by
 * exactly one run (`takeOver`); an owner file still missing or unparseable is waited for through a grace period.
 */
@:nullSafety(Strict)
final class OracleGenerationLock {

	/** A lock older than this is taken over even when its pid is alive — a pid the system reused for something else. */
	private static inline final MAX_LOCK_AGE: Float = 6 * 60 * 60 * 1000;

	/** How long a lock directory may exist without its owner file before it counts as abandoned, in ms. */
	private static inline final OWNERLESS_GRACE: Float = 10 * 1000;

	/** How often a waiting hold looks again, in ms. */
	private static inline final LOCK_POLL: Int = 250;

	/** This process as a lock holder: its pid and its start time (`startTime`), which together outlive pid reuse. */
	public static function holder(): Holder {
		#if nodejs
		final pid: Int = js.Node.process.pid;
		return { pid: pid, start: startTime(pid) };
		#else
		return { pid: 0, start: '' };
		#end
	}

	/**
	 * Take a SHARED hold on the lock `dir` for `me`: a `readers/<pid>` file, kept only while no other live holder owns the
	 * exclusive `writer` directory (a writer that is waiting counts, so readers cannot starve it). Null when held, else
	 * why not once `deadline` passed. An abandoned writer is taken over (`takeOver`) rather than waited for. Without a
	 * node process API there is no lock, and this holds trivially.
	 */
	public static function holdShared(dir: String, me: Holder, deadline: Float): Null<String> {
		#if nodejs
		final reader: String = Path.join([dir, 'readers', '${me.pid}']);
		sys.FileSystem.createDirectory(Path.join([dir, 'readers']));
		while (true) {
			writeAtomically(reader, me.start);
			final writer: Null<LockOwner> = writerOf(dir);
			if (writer == null || isMe(writer, me)) return null;
			deleteQuietly(reader);
			if (writer.abandoned) {
				takeOver(dir, writer);
				continue;
			}
			if (Date.now().getTime() > deadline) return 'another apq run (pid ${writer.pid}) is regenerating it';
			pause();
		}
		#else
		return null;
		#end
	}

	/**
	 * Take the EXCLUSIVE hold on the lock `dir` for `me` — the `writer` directory, created atomically, with an `owner`
	 * file written whole by a rename — and then wait until no OTHER live run holds it shared. Dead readers are cleared as
	 * they are found. Null when held, else why not once `deadline` passed (and nothing is held then).
	 */
	public static function holdExclusive(dir: String, me: Holder, deadline: Float): Null<String> {
		#if nodejs
		final writer: String = Path.join([dir, 'writer']);
		sys.FileSystem.createDirectory(dir);
		while (true) {
			final created: Bool = try {
				js.node.Fs.mkdirSync(writer);
				true;
			} catch (exception: haxe.Exception) false;
			if (created) {
				writeAtomically(Path.join([writer, 'owner']), '${me.pid}\n${me.start}\n${Date.now().getTime()}');
				break;
			}
			final held: Null<LockOwner> = writerOf(dir);
			if (held != null && isMe(held, me)) break;
			if (held != null && held.abandoned) {
				takeOver(dir, held);
				continue;
			}
			if (Date.now().getTime() > deadline) return 'another apq run (pid ${held?.pid}) is regenerating it';
			pause();
		}
		while (true) {
			final others: Array<Int> = liveReaders(dir, me);
			if (others.length == 0) return null;
			if (Date.now().getTime() > deadline) {
				dropExclusive(dir, me);
				return '${others.length} other apq run(s) (pid ${others.join(', ')}) are still compiling it';
			}
			pause();
		}
		#else
		return null;
		#end
	}

	/** Drop `me`'s shared hold on `dir`. */
	public static function dropShared(dir: String, me: Holder): Void {
		#if nodejs
		deleteQuietly(Path.join([dir, 'readers', '${me.pid}']));
		#end
	}

	/** Drop `me`'s exclusive hold on `dir`, and only `me`'s. */
	public static function dropExclusive(dir: String, me: Holder): Void {
		#if nodejs
		final held: Null<LockOwner> = writerOf(dir);
		if (held != null && isMe(held, me)) removeTree(Path.join([dir, 'writer']));
		#end
	}

	#if nodejs
	/**
	 * When process `pid` started, as `ps` reports it — the second half of a holder's identity, so a pid the system reused
	 * reads as a different process. Empty when it cannot be told (no `ps`, Windows): the pid alone is trusted then.
	 */
	public static function startTime(pid: Int): String {
		if (js.Node.process.platform == 'win32') return '';
		final res: Dynamic = js.node.ChildProcess.spawnSync('ps', ['-o', 'lstart=', '-p', '$pid'], { encoding: 'utf8' });
		return res.status == 0 ? '${res.stdout}'.trim() : '';
	}

	/** Whether the holder `pid` / `start` still runs: the pid answers a signal-0 probe, and started when it says it did. */
	private static function living(pid: Int, start: String): Bool {
		final signalable: Bool = try {
			js.Syntax.code('process.kill({0}, 0)', pid);
			true;
		} catch (exception: haxe.Exception) '${Reflect.field(exception.native, 'code')}' == 'EPERM';
		return signalable && (start == '' || startTime(pid) == start);
	}

	/** The pids of every live run other than `me` holding `dir` shared; a dead one's file is removed on the way. */
	private static function liveReaders(dir: String, me: Holder): Array<Int> {
		final readers: String = Path.join([dir, 'readers']);
		final entries: Array<String> = try sys.FileSystem.readDirectory(readers) catch (exception: haxe.Exception) [];
		final out: Array<Int> = [];
		for (entry in entries) {
			final pid: Null<Int> = Std.parseInt(entry);
			if (pid == null || '$pid' != entry || pid == me.pid) continue;
			final start: Null<String> = try sys.io.File.getContent(Path.join([readers, entry])) catch (exception: haxe.Exception) null;
			if (start != null && living(pid, start.trim()))
				out.push(pid)
			else if (start != null)
				deleteQuietly(Path.join([readers, entry]));
		}
		return out;
	}

	/**
	 * The owner of `dir`'s exclusive hold, or null when there is none. An owner file that is missing or unparseable (a
	 * writer between its `mkdir` and its rename) is abandoned only once the directory is older than `OWNERLESS_GRACE`; a
	 * parsed one is abandoned when its holder no longer runs, or — with no start time to check — past `MAX_LOCK_AGE`.
	 */
	public static function writerOf(dir: String): Null<LockOwner> {
		final writer: String = Path.join([dir, 'writer']);
		if (!sys.FileSystem.exists(writer)) return null;
		final text: Null<String> = try sys.io.File.getContent(Path.join([writer, 'owner'])) catch (exception: haxe.Exception) null;
		final fields: Array<String> = (text ?? '').split('\n');
		final pid: Null<Int> = Std.parseInt(fields[0]);
		final now: Float = Date.now().getTime();
		if (pid == null || fields.length < 3) return {
			pid: null,
			start: '',
			identity: 'ownerless ${modified(writer)}',
			abandoned: now - modified(writer) > OWNERLESS_GRACE
		};
		final start: String = fields[1];
		final since: Float = Std.parseFloat(fields[2]);
		return {
			pid: pid,
			start: start,
			identity: text ?? '',
			abandoned: !living(pid, start) || start == '' && now - since > MAX_LOCK_AGE
		};
	}

	/**
	 * Break the abandoned exclusive hold `stale` on `dir`. Exactly one run wins a race over the same stale owner: the
	 * claim is a `mkdir` named after that owner, and the winner removes the `writer` directory only after checking it
	 * still belongs to that owner — a run that judged the owner stale too late finds a fresh writer and leaves it alone.
	 */
	public static function takeOver(dir: String, stale: LockOwner): Bool {
		final claim: String = Path.join([dir, 'takeover-${haxe.crypto.Md5.encode(stale.identity)}']);
		final won: Bool = try {
			js.node.Fs.mkdirSync(claim);
			true;
		} catch (exception: haxe.Exception) false;
		if (!won) return false;
		final current: Null<LockOwner> = writerOf(dir);
		final same: Bool = current != null && current.identity == stale.identity;
		if (same) removeTree(Path.join([dir, 'writer']));
		removeTree(claim);
		return same;
	}

	private static inline function isMe(owner: LockOwner, me: Holder): Bool {
		return owner.pid == me.pid && owner.start == me.start;
	}

	/** Write `content` to `path` whole: a temporary file renamed into place, so no reader ever sees it half written. */
	private static function writeAtomically(path: String, content: String): Void {
		final temporary: String = '$path.tmp-${js.Node.process.pid}';
		sys.io.File.saveContent(temporary, content);
		sys.FileSystem.rename(temporary, path);
	}

	private static function deleteQuietly(path: String): Void {
		try if (sys.FileSystem.exists(path)) sys.FileSystem.deleteFile(path) catch (exception: haxe.Exception) {} // noqa: swallowed-exception
	}

	/** Remove `path` and everything under it; a part already gone is no error. */
	private static function removeTree(path: String): Void {
		try js.Syntax.code(
			"require('fs').rmSync({0}, { recursive: true, force: true })", path
		) catch (exception: haxe.Exception) {} // noqa: swallowed-exception
	}

	private static inline function pause(): Void {
		js.Syntax.code('Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, {0})', LOCK_POLL);
	}
	#end

	#if nodejs
	/** `path`'s modification time in ms, or now when it cannot be read. */
	private static function modified(path: String): Float {
		return try sys.FileSystem.stat(path).mtime.getTime() catch (exception: haxe.Exception) Date.now().getTime();
	}
	#end

}

/** One `apq` process as a lock holder: its pid, and when it started (empty when that cannot be told). */
typedef Holder = {
	var pid: Int;
	var start: String;
}

/**
 * The owner of a generation's exclusive hold as read off its `owner` file: pid and start time (null / empty when the
 * file is missing or unparseable), the text that identifies this particular hold, and whether it is abandoned.
 */
typedef LockOwner = {
	var pid: Null<Int>;
	var start: String;
	var identity: String;
	var abandoned: Bool;
}

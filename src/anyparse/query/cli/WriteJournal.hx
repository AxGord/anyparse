package anyparse.query.cli;

using Lambda;

/**
 * A path as one run's writes found it: its text and permission bits before the run first touched it, both null when it
 * did not exist.
 */
typedef JournalEntry = {
	final path: String;
	final original: Null<String>;
	final mode: Null<Int>;
}

/** A path's text at one moment, or null when it does not exist. */
typedef JournalState = {
	final path: String;
	final content: Null<String>;
}

/**
 * Every file one command run wrote or deleted, with what it held before — what a post-write check needs to put the
 * run's work back (`rollback`) or to write it again (`replay`).
 *
 * The dispatcher opens one per write command (`during`) and `CliIo`'s write path reports each path to it (`note`), so no
 * op records anything of its own. The recording seat lives only as long as the `during` call that opened it and is put
 * back when that call ends, normally or by a throw: it never outlives the run it describes.
 */
@:nullSafety(Strict)
final class WriteJournal {

	/** The journal of the run in progress, set only inside `during`. */
	private static var recording: Null<WriteJournal> = null;

	private final _entries: Array<JournalEntry> = [];

	/** The directories the run's writes created, in creation order. */
	private final _directories: Array<String> = [];

	public function new() {}

	/** Every recorded path whose text now differs from what it held before the run. */
	public function changed(): Array<String> {
		return [for (entry in _entries) if (read(entry.path) != entry.original) entry.path];
	}

	/** Whether the run created a file or deleted one — a change to the module set, not only to a module's text. */
	public function createdOrDeleted(): Bool {
		return _entries.exists(entry -> (entry.original == null) != (read(entry.path) == null));
	}

	/** Every recorded path's text before the run. */
	public function originals(): Array<JournalState> {
		return [for (entry in _entries) { path: entry.path, content: entry.original }];
	}

	/** Every recorded path's text now — what `replay` writes back after a `rollback`. */
	public function current(): Array<JournalState> {
		return [for (entry in _entries) { path: entry.path, content: read(entry.path) }];
	}

	/**
	 * Put every recorded path back as it was before the run — a deleted file with its permission bits, which a restaged
	 * write cannot copy from a target that is gone — and remove the directories the run created.
	 */
	public function rollback(): Void {
		replay(originals());
		#if nodejs
		for (entry in _entries) {
			final mode: Null<Int> = entry.mode;
			if (mode != null && sys.FileSystem.exists(entry.path)) js.node.Fs.chmodSync(entry.path, mode);
		}
		#end
		CliIo.removeCreatedDirectories(_directories);
	}

	/** Write each of `states` — a path whose content is null is deleted. */
	public function replay(states: Array<JournalState>): Void {
		CliIo.writeFiles([for (s in states) if (s.content != null) { path: s.path, content: s.content }]);
		for (s in states) if (s.content == null) CliIo.deletePath(s.path);
	}

	private function record(path: String): Void {
		final absolute: String = ConfigFinder.absolute(path);
		if (_entries.exists(entry -> entry.path == absolute)) return;
		final original: Null<String> = read(absolute);
		final mode: Null<Int> = #if (sys || nodejs) original == null
			? null
			: sys.FileSystem.stat(absolute).mode & CliIo.PERMISSION_BITS #else null #end;
		_entries.push({ path: absolute, original: original, mode: mode });
	}

	/** Record `path`, about to be written or deleted, in the run's journal — a no-op outside `during`, and for a path already recorded. */
	public static inline function note(path: String): Void {
		recording?.record(path);
	}

	/** Run `body` with `journal` recording every write `CliIo` makes, and answer what `body` answered. */
	public static function during<T>(journal: WriteJournal, body: () -> T): T {
		final outer: Null<WriteJournal> = recording;
		recording = journal;
		final result: T = try body() catch (exception: Exception) {
			recording = outer;
			throw exception;
		}
		recording = outer;
		return result;
	}

	/** Record `created`, the directories a write just made, in the run's journal — a no-op outside `during`. */
	public static function noteDirectories(created: Array<String>): Void {
		final journal: Null<WriteJournal> = recording;
		if (journal != null) for (dir in created) if (!journal._directories.contains(dir)) journal._directories.push(dir);
	}

	private static function read(path: String): Null<String> {
		return #if (sys || nodejs) sys.FileSystem.exists(path) ? CliIo.readFile(path) : null #else null #end;
	}

}

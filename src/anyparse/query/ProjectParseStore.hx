package anyparse.query;

import anyparse.core.ParseProjectionEngine;
import anyparse.query.ParseDiskCache.StoredProjections;
import anyparse.query.SpanTypeInfoProvider.SpanTypeInfo;
import anyparse.query.SymbolIndex.FileInfo;
import haxe.Exception;
import haxe.Timer;

/**
 * The one answer to "do this project's file parses come from, and go to, the disk store": it hands an index build the
 * parse `ParseDiskCache` holds for a project file (`seat`) and takes back what the build parsed (`keep`), one file at a
 * time so nothing is retained beyond the build; a record derived from the parse (`ProjectOutlines`) goes the same way
 * (`record`, `keepRecord`), keyed also by the code that derives it. Writes are capped by a share of the build's own elapsed time, so a cold
 * run costs a bounded amount more and successive runs fill the store.
 *
 * Nothing enters a process-scoped map (`docs/design-principles.md` § 2); the store itself checks each entry against the
 * file's bytes, so a changed file is a miss and never a stale hit.
 */
@:nullSafety(Strict)
final class ProjectParseStore {

	private static inline final DEFAULT_BUDGET: Float = 0.03;

	/** A record is derived from a parse by query code the parse's own engine key leaves out, so it is keyed by that code too. */
	private static final RECORD_TAG: String = 'apq-derived-record v1 ${ParseProjectionEngine.outlineDigest()}';

	/** The record kind of a file's extracted `FileInfo`, kept before the index's cross-file ambient pass fills it in. */
	private static final DECLARATIONS_KIND: String = 'declarations';

	private final _started: Float = Timer.stamp();
	private final _disk: ParseDiskCache;
	private final _budget: Float;

	private var _written: Int = 0;
	private var _spent: Float = 0;

	/** `budget` is the share of the build's own elapsed time the writes may take. */
	public function new(lang: String, budget: Float = DEFAULT_BUDGET) {
		_disk = new ParseDiskCache(lang);
		_budget = budget;
	}

	/** How many entries this store has written. */
	public inline function written(): Int {
		return _written;
	}

	/** What the store holds for `file` when its bytes are `source`; null for a file not on disk or a miss. */
	public function seat(file: String, source: String): Null<StoredProjections> {
		return onDisk(file) ? _disk.lookup(file, source) : null;
	}

	/**
	 * Write the parse a build made of `file`, unless the writes so far have used their share of the build's elapsed time. The
	 * first write is always allowed, so repeated runs fill the store one stretch at a time and converge to all stored.
	 */
	public function keep(file: String, source: String, tree: QueryNode, spans: SpanTypeInfo): Void {
		writeWithinBudget(file, () -> _disk.store(file, source, tree, spans));
	}

	/** The record of kind `kind` the store holds for `file` when its bytes are `source`; null for a file not on disk or a miss. */
	public function record(file: String, source: String, kind: String): Null<String> {
		return onDisk(file) ? _disk.lookupRecord(file, source, kind, RECORD_TAG) : null;
	}

	/**
	 * Write the record of kind `kind` a build derived from `file`, under the same share of the build's elapsed time as `keep`;
	 * `record` is only called when the budget allows the write.
	 */
	public function keepRecord(file: String, source: String, kind: String, record: () -> String): Void {
		writeWithinBudget(file, () -> _disk.storeRecord(file, source, kind, RECORD_TAG, record()));
	}

	/**
	 * The `FileInfo` an index build extracted from `file` when its bytes were `source`, for a build to take instead of
	 * parsing and walking it; null for a file not on disk, a miss, or a record that does not decode to that file.
	 */
	public function declarations(file: String, source: String): Null<FileInfo> {
		final text: Null<String> = record(file, source, DECLARATIONS_KIND);
		if (text == null) return null;
		try {
			final info: FileInfo = haxe.Unserializer.run(text);
			return info.file == file ? info : null;
		} catch (_: Exception) {
			return null;
		}
	}

	/** Keep `info`, extracted from `source`, as its file's `declarations`, under the same budget as `keep`. */
	public function keepDeclarations(info: FileInfo, source: String): Void {
		keepRecord(info.file, source, DECLARATIONS_KIND, () -> haxe.Serializer.run(info));
	}

	private inline function withinBudget(now: Float): Bool {
		return _written == 0 || _spent <= _budget * (now - _started);
	}

	private function writeWithinBudget(file: String, write: () -> Void): Void {
		// A closed cache writes nothing, so the record is not even derived.
		if (!onDisk(file) || !_disk.open()) return;
		final before: Float = Timer.stamp();
		if (!withinBudget(before)) return;
		write();
		_written++;
		_spent += Timer.stamp() - before;
	}

	private static function onDisk(file: String): Bool {
		return #if (sys || nodejs) file != '' && sys.FileSystem.exists(file) #else false #end;
	}

}

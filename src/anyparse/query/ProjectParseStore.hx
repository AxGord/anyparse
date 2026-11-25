package anyparse.query;

import anyparse.query.ParseDiskCache.StoredProjections;
import anyparse.query.SpanTypeInfoProvider.SpanTypeInfo;
import haxe.Timer;

/**
 * The one answer to "do this project's file parses come from, and go to, the disk store": it hands an index build the
 * parse `ParseDiskCache` holds for a project file (`seat`) and takes back what the build parsed (`keep`), one file at a
 * time so nothing is retained beyond the build. Writes are capped by a share of the build's own elapsed time, so a cold
 * run costs a bounded amount more and successive runs fill the store.
 *
 * Nothing enters a process-scoped map (`docs/design-principles.md` § 2); the store itself checks each entry against the
 * file's bytes, so a changed file is a miss and never a stale hit.
 */
@:nullSafety(Strict)
final class ProjectParseStore {

	private static inline final DEFAULT_BUDGET: Float = 0.03;

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
		if (!onDisk(file)) return;
		final before: Float = Timer.stamp();
		if (!withinBudget(before)) return;
		_disk.store(file, source, tree, spans);
		_written++;
		_spent += Timer.stamp() - before;
	}

	private inline function withinBudget(now: Float): Bool {
		return _written == 0 || _spent <= _budget * (now - _started);
	}

	private static function onDisk(file: String): Bool {
		return #if (sys || nodejs) file != '' && sys.FileSystem.exists(file) #else false #end;
	}

}

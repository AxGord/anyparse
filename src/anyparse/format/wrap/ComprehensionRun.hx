package anyparse.format.wrap;

import anyparse.core.CollectionRun;
import anyparse.core.Doc;

/**
 * The one answer to "does this collection argument stand in a run of collection arguments that holds an array
 * comprehension". Such a run is one unit of its call's fill, laid out one collection per line when it is wider than a
 * line, so no member of it rides the close of a broken one.
 */
@:nullSafety(Strict)
final class ComprehensionRun {

	/**
	 * True iff `items[idx]` is a collection in a run of two or more (`CollectionRun`) of which one is a comprehension, as
	 * `comprehensions` (`WrapListOptions.comprehensionItems`, the grammar's reading of the AST) marks it.
	 */
	public static function holds(items: Array<Doc>, idx: Int, comprehensions: Null<Array<Bool>>): Bool {
		if (comprehensions == null || !CollectionRun.startsCollection(items[idx])) return false;
		final from: Int = CollectionRun.collectionRunStart(items, idx);
		final to: Int = CollectionRun.collectionRunEnd(items, idx);
		if (from == to) return false;
		for (k in from ... to + 1) if (comprehensions[k] == true) return true;
		return false;
	}

}

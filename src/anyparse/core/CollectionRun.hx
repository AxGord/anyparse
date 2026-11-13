package anyparse.core;

/**
	The one answer to "which consecutive fill items form one run of collection
	(literal) arguments": a fill lays such a run out as a single unit.
**/
@:nullSafety(Strict)
final class CollectionRun {

	/**
	 * ω-fill-after-collection: does this fill item open with a collection
	 * delimiter (`[` array / comprehension, `{` object literal / anon type)?
	 *
	 * Structural, not width-based: the brackets are the boundary a reader
	 * navigates by, so the followers belong on one side of them or the other —
	 * never split across. `DocMeasure.firstVisibleTextStartsWith` walks to the
	 * first emitted byte, so a leading `Group` / `Nest` / wrap marker is
	 * transparent here.
	 */
	public static function startsCollection(item: Doc): Bool {
		// An EMPTY collection is not a boundary — `f({}, cb -> …)` has nothing for the reader to navigate around, and
		// pushing `cb` off its line only strands a two-character `{},`; its one-leaf pair is tagged `EmptyCollection`.
		return switch DocMeasure.firstVisibleLeaf(item) {
			case Text(_, _, Delimiter(Collection, _)): true;
			case _: false;
		};
	}

	/**
	 * The first index of the run of consecutive collection items holding `idx`.
	 */
	public static function collectionRunStart(items: Array<Doc>, idx: Int): Int {
		var s: Int = idx;
		while (s > 0 && startsCollection(items[s - 1])) s--;
		return s;
	}

	/** The last index of the run of consecutive collection items holding `idx`. */
	public static function collectionRunEnd(items: Array<Doc>, idx: Int): Int {
		var e: Int = idx;
		while (e + 1 < items.length && startsCollection(items[e + 1])) e++;
		return e;
	}

	/** The flat projection of the items `from..to` joined by `sep`. */
	public static function collectionRunDoc(items: Array<Doc>, sep: Doc, from: Int, to: Int): Doc {
		final parts: Array<Doc> = [items[from]];
		for (i in from + 1...to + 1) {
			parts.push(sep);
			parts.push(items[i]);
		}
		return Concat(parts);
	}

	/**
	 * ω-fill-after-collection: `fillRest[idx…]` joined by `sep`, for the
	 * "does the WHOLE tail still fit on this line" probe.
	 */
	public static function remainingFlat(fillRest: Array<Doc>, sep: Doc, idx: Int): Doc {
		final parts: Array<Doc> = [];
		for (i in idx ... fillRest.length) {
			parts.push(sep);
			parts.push(fillRest[i]);
		}
		return Concat(parts);
	}

}

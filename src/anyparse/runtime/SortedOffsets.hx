package anyparse.runtime;

/**
 * Range questions over an ascending array of offsets, answered by binary search — the per-call scan of a whole
 * offset-keyed map they replace was linear in the file.
 */
@:nullSafety(Strict)
final class SortedOffsets {

	/** The smallest of the ascending `sorted` inside `[from, to)`, -1 when none is. */
	public static function firstIn(sorted: Array<Int>, from: Int, to: Int): Int {
		var lo: Int = 0;
		var hi: Int = sorted.length;
		while (lo < hi) {
			final mid: Int = (lo + hi) >> 1;
			if (sorted[mid] < from)
				lo = mid + 1
			else
				hi = mid;
		}
		return lo < sorted.length && sorted[lo] < to ? sorted[lo] : -1;
	}

}

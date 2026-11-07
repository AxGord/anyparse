package anyparse.util;

/**
 * The one answer to "which of two values comes first": three-way comparators for `Array.sort`, where each returns exactly
 * -1, 0 or 1. Strings compare by the target's String order (code unit
 * on js), never by locale. This package imports nothing from `anyparse.*`, and it holds no state.
 */
final class Compare {

	/** Order of two integers: -1, 0 or 1. */
	public static inline function compareInt(a: Int, b: Int): Int {
		return if (a < b)
			-1
		else if (a > b)
			1
		else
			0;
	}

	/** Order of two strings by the target's String order: -1, 0 or 1. */
	public static inline function compareString(a: String, b: String): Int {
		return if (a < b)
			-1
		else if (a > b)
			1
		else
			0;
	}

}

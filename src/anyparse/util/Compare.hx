package anyparse.util;

import haxe.macro.Expr;

/**
 * The one answer to "which of two values comes first": three-way comparators for `Array.sort`, where each returns exactly
 * -1, 0 or 1, and `asc` / `desc`, which build one such comparator from key lambdas. Strings compare by the target's String order
 * (code unit on js), never by locale. This package imports nothing from `anyparse.*`, and it holds no state.
 */
final class Compare {

	/**
	 * Order of two integers: -1, 0 or 1. Not `a - b`: Int is 32-bit on the static targets, so the subtraction overflows
	 * (`compareInt(2147483647, -1)` would turn negative); the branches are the portable form.
	 */
	public static inline function compareInt(a: Int, b: Int): Int {
		return if (a < b) -1 else if (a > b) 1 else 0;
	}

	/** Order of two strings by the target's String order: -1, 0 or 1. */
	public static inline function compareString(a: String, b: String): Int {
		return if (a < b) -1 else if (a > b) 1 else 0;
	}

	/**
	 * Order of two floats: -1, 0 or 1. Not `a - b`: the difference is a Float, and truncating it to the Int a comparator returns
	 * makes a gap under one compare as equal. A `NaN` on either side answers 0, as both branch tests are false; the callers that
	 * rewrite a hand-written chain to this function rely on that being the chain's own answer.
	 */
	public static inline function compareFloat(a: Float, b: Float): Int {
		return if (a < b) -1 else if (a > b) 1 else 0;
	}

	/**
	 * A comparator ordering by the key lambdas in turn, ascending: `rows.sort(Compare.asc(r -> r.a, r -> r.b))`. It expands at
	 * compile time into ONE `(x, y) -> Int` lambda, key by key, so it costs what the hand-written comparator costs. A key
	 * wrapped in `Compare.desc(…)` is read descending. The element type comes from the expected type, or from a key
	 * parameter's annotation; a key is a one-expression lambda of Int, Float or String (a `Null<…>` key is refused).
	 */
	public static macro function asc(keys: Array<Expr>): Expr {
		return CompareKeys.comparator(keys, true);
	}

	/** `asc` with every key descending unless it is wrapped in `Compare.asc(…)`. */
	public static macro function desc(keys: Array<Expr>): Expr {
		return CompareKeys.comparator(keys, false);
	}

}

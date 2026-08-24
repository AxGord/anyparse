package anyparse.runtime;

using StringTools;

import haxe.Exception;

/**
 * Levenshtein distance with a ceiling.
 *
 * Every caller in this project asks the same question — "is `a` within N
 * edits of `b`" — and none needs a distance past that N, so the exact
 * value is computed only while it stays under the ceiling and the walk
 * abandons as soon as a whole row is at least that far. On an unrelated
 * candidate that ends the work after one row instead of `a.length` of
 * them, which matters because the callers scan a whole vocabulary per
 * query.
 *
 * Lives in `anyparse.runtime` because that is the lowest layer any
 * caller shares: the generated parsers' unknown-key suggestion
 * (`UnknownField`) sits here, and the CLI's "did you mean" reaches DOWN
 * to it. It is pure text arithmetic with no parser state — the package
 * is about layering, not about parsing.
 */
@:nullSafety(Strict)
final class EditDistance {

	/**
	 * The edit distance between `a` and `b` when that is below `limit`,
	 * and `limit` itself — meaning "at least this far" — otherwise.
	 *
	 * The sentinel is what makes a caller's `d < budget` test safe: a
	 * value at or above `limit` is never a real distance, so it can only
	 * lose a comparison, never win one. Pass `limit` one greater than the
	 * largest distance you would accept.
	 */
	public static function between(a: String, b: String, limit: Int): Int {
		if (limit < 1) throw new Exception('EditDistance.between needs a limit of at least 1, got $limit');
		final aLen: Int = a.length;
		final bLen: Int = b.length;
		final spread: Int = aLen > bLen ? aLen - bLen : bLen - aLen;
		if (spread >= limit) return limit;
		if (aLen == 0) return bLen;
		if (bLen == 0) return aLen;
		var previous: Array<Int> = [for (j in 0...bLen + 1) j];
		var current: Array<Int> = [for (j in 0...bLen + 1) 0];
		for (i in 1...aLen + 1) {
			current[0] = i;
			final ai: Int = a.fastCodeAt(i - 1);
			var rowMin: Int = i;
			for (j in 1...bLen + 1) {
				final substitution: Int = previous[j - 1] + (ai == b.fastCodeAt(j - 1) ? 0 : 1);
				final deletion: Int = previous[j] + 1;
				final insertion: Int = current[j - 1] + 1;
				var cell: Int = deletion < insertion ? deletion : insertion;
				if (substitution < cell) cell = substitution;
				current[j] = cell;
				if (cell < rowMin) rowMin = cell;
			}
			if (rowMin >= limit) return limit;
			final swap: Array<Int> = previous;
			previous = current;
			current = swap;
		}
		final distance: Int = previous[bLen];
		return distance < limit ? distance : limit;
	}

}

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

	/** Levenshtein ceiling for a `closest` tier-1 candidate — a typo or a transposition, not a different word. */
	private static inline final FUZZY_MAX_DIST: Int = 3;

	/** How many candidates `closest` returns. */
	private static inline final FUZZY_TOP_K: Int = 3;

	/**
	 * Substring "did you mean" — `query` >= this length OR the substring
	 * pre-filter is skipped (avoids `Hx` matching every grammar type).
	 */
	private static inline final FUZZY_SUBSTRING_MIN_QUERY: Int = 4;

	/**
	 * Substring "did you mean" — candidate's extra char count over
	 * `query.length` must not exceed this (avoids `Foo` matching a huge
	 * `FooSomeReallyLongName` and crowding out true neighbours).
	 */
	private static inline final FUZZY_SUBSTRING_MAX_EXTRA: Int = 8;

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

	/**
	 * Top-`FUZZY_TOP_K` "did you mean" candidates from `pool`, ranked in two tiers:
	 *
	 *  - Tier 0 — substring match: `query` is a contiguous substring of `cand`
	 *    (prefix/suffix/inner). Score = extra char count `cand.length -
	 *    query.length`. Catches the common grammar miss `HxTypeParam` ->
	 *    `HxTypeParamDecl` (Levenshtein distance 4 from appending "Decl" — beyond
	 *    `FUZZY_MAX_DIST`, but `HxTypeParam` IS a substring of `HxTypeParamDecl`).
	 *    Guarded by `FUZZY_SUBSTRING_MIN_QUERY` (avoids `Hx` matching everything)
	 *    and `FUZZY_SUBSTRING_MAX_EXTRA` (avoids `Foo` crowding out true
	 *    neighbours with a long-name match).
	 *
	 *  - Tier 1 — Levenshtein within `FUZZY_MAX_DIST`. Catches typos and
	 *    transpositions a substring scan can't.
	 *
	 * A candidate that qualifies under Tier 0 is NOT also evaluated under Tier 1 —
	 * the substring tier always wins, and we don't double-add. Returns empty when
	 * nothing qualifies; the caller emits the "did you mean" line only on a
	 * non-empty result (never fabricates hints).
	 *
	 * Lives beside the metric rather than in the CLI because a vocabulary worth
	 * ranking is not always the CLI's: a `--select` segment's kind is checked
	 * against the GRAMMAR's projected set in `anyparse.query`, which cannot reach
	 * `anyparse.query.cli`.
	 */
	public static function closest(query: String, pool: Array<String>): Array<String> {
		final scored: Array<{ name: String, tier: Int, score: Int }> = [];
		final qLen: Int = query.length;
		final substringEnabled: Bool = qLen >= FUZZY_SUBSTRING_MIN_QUERY;
		for (cand in pool) if (cand != query) {
			if (substringEnabled && cand.length > qLen && cand.length - qLen <= FUZZY_SUBSTRING_MAX_EXTRA && cand.indexOf(query) >= 0) {
				scored.push({ name: cand, tier: 0, score: cand.length - qLen });
				continue;
			}
			// `FUZZY_MAX_DIST + 1` as the ceiling: every distance the tier keeps comes back
			// exact, and anything further comes back as the ceiling itself, which the test
			// below rejects.
			final d: Int = between(query, cand, FUZZY_MAX_DIST + 1);
			if (d <= FUZZY_MAX_DIST) scored.push({ name: cand, tier: 1, score: d });
		}
		scored.sort((a, b) ->
			if (a.tier != b.tier)
				a.tier - b.tier
			else if (a.score != b.score)
				a.score - b.score
			else if (a.name < b.name)
				-1
			else
				1
		);
		final take: Int = scored.length < FUZZY_TOP_K ? scored.length : FUZZY_TOP_K;
		return [for (i in 0...take) scored[i].name];
	}

}

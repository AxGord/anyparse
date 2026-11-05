package anyparse.macro;

using StringTools;

/**
 * An immutable set of UTF-16 code units, held as sorted disjoint inclusive ranges. The character sets of a
 * `RegexScanPlan`. Deliberately not `#if macro`: the plan's soundness rests on a test, and a test runs on js.
 */
@:nullSafety(Strict)
final class CodeSet {

	/** The highest code unit a set may hold. */
	public static inline final MAX_CODE: Int = 0xFFFF;

	/** Sorted, disjoint and never adjacent, so two equal sets hold equal ranges. */
	public final ranges: Array<CodeRange>;

	private function new(ranges: Array<CodeRange>) {
		this.ranges = ranges;
	}

	public inline function isEmpty(): Bool {
		return ranges.length == 0;
	}

	public function union(other: CodeSet): CodeSet {
		final pairs: Array<Int> = [];
		for (set in [this, other]) for (range in set.ranges) {
			pairs.push(range.lo);
			pairs.push(range.hi);
		}
		return of(pairs);
	}

	public function complement(): CodeSet {
		final pairs: Array<Int> = [];
		var from: Int = 0;
		for (range in ranges) {
			if (range.lo > from) {
				pairs.push(from);
				pairs.push(range.lo - 1);
			}
			from = range.hi + 1;
		}
		if (from <= MAX_CODE) {
			pairs.push(from);
			pairs.push(MAX_CODE);
		}
		return of(pairs);
	}

	public function intersects(other: CodeSet): Bool {
		for (a in ranges) for (b in other.ranges) if (a.lo <= b.hi && b.lo <= a.hi) return true;
		return false;
	}

	/** The single code this set holds, or -1 when it holds any other number of them. */
	public function soleCode(): Int {
		return ranges.length == 1 && ranges[0].lo == ranges[0].hi ? ranges[0].lo : -1;
	}

	public static inline function single(code: Int): CodeSet {
		return of([code, code]);
	}

	public static inline function empty(): CodeSet {
		return of([]);
	}

	public static inline function all(): CodeSet {
		return of([0, MAX_CODE]);
	}

	/** The set of `pairs`, a flat list of inclusive `lo, hi` bounds in any order. */
	public static function of(pairs: Array<Int>): CodeSet {
		final given: Array<CodeRange> = [for (i in 0...pairs.length >> 1) { lo: pairs[i << 1], hi: pairs[(i << 1) + 1] }];
		given.sort((a: CodeRange, b: CodeRange) -> a.lo - b.lo);
		final merged: Array<CodeRange> = [];
		for (range in given) {
			final last: Null<CodeRange> = merged.length == 0 ? null : merged[merged.length - 1];
			if (last != null && range.lo <= last.hi + 1)
				merged[merged.length - 1] = { lo: last.lo, hi: range.hi > last.hi ? range.hi : last.hi };
			else
				merged.push(range);
		}
		return new CodeSet(merged);
	}

	/** The set of the code units `chars` holds. */
	public static function ofChars(chars: String): CodeSet {
		final pairs: Array<Int> = [];
		for (i in 0...chars.length) {
			final code: Int = chars.fastCodeAt(i);
			pairs.push(code);
			pairs.push(code);
		}
		return of(pairs);
	}

}

/** An inclusive run of code units. */
typedef CodeRange = {
	final lo: Int;
	final hi: Int;
}

package anyparse.runtime;

/**
 * The one answer to "which literals did this parse match, and where": every literal a span parse matched and kept,
 * as ascending `[from, to)` pairs. The generated `matchLit` records each match through `push`, so a token is known by
 * the declaration that matched it, never by a second read of the text.
 *
 * A rewind is not observed directly. A match at `from` proves every entry starting at or after `from` was matched by a
 * branch the parser has since left, so `push` drops them first, and a memoised rule's replay pushes the tokens its
 * recorded run kept (`Parser.memoReplay`). A helper that rewinds over its own match without matching again — a keyword
 * failing its word boundary — calls `retract`. Scoped to one parse like every other field of `Parser`.
 */
@:nullSafety(Strict)
final class TokenLog {

	/** `[from0, to0, from1, to1, …]`, ascending by `from`. */
	private var _pairs: Array<Int> = [];

	public function new() {}

	/** How many tokens the log holds. */
	public inline function count(): Int {
		return _pairs.length >> 1;
	}

	/** Where token `index` starts. */
	public inline function fromAt(index: Int): Int {
		return _pairs[index << 1];
	}

	/** Where token `index` ends. */
	public inline function toAt(index: Int): Int {
		return _pairs[(index << 1) + 1];
	}

	/** Record a literal matched over `[from, to)`, dropping the entries a rewind past `from` left behind. */
	public function push(from: Int, to: Int): Void {
		retract(from);
		_pairs.push(from);
		_pairs.push(to);
	}

	/** Drop every entry starting at or after `from`: the parser has rewound to `from` and matched nothing there yet. */
	public function retract(from: Int): Void {
		var kept: Int = _pairs.length;
		while (kept >= 2 && _pairs[kept - 2] >= from) kept -= 2;
		if (kept < _pairs.length) _pairs.resize(kept);
	}

	/** The index of the first token in `[lo, hi)` starting at or after `at`; `hi` when none does. */
	public function firstAtOrAfter(at: Int, lo: Int, hi: Int): Int {
		var low: Int = lo;
		var high: Int = hi;
		while (low < high) {
			final mid: Int = (low + high) >> 1;
			if (fromAt(mid) < at)
				low = mid + 1
			else
				high = mid;
		}
		return low;
	}

	/** The pairs of the tokens starting inside `[from, to)`, in order — what a memoised run from `from` kept; null when none do. */
	public function between(from: Int, to: Int): Null<Array<Int>> {
		final first: Int = firstAtOrAfter(from, 0, count());
		final last: Int = firstAtOrAfter(to, first, count());
		return first == last ? null : _pairs.slice(first << 1, last << 1);
	}

	/** Every pair, in order — what `replay` rebuilds the log from. */
	public function pairs(): Array<Int> {
		return _pairs.copy();
	}

	/** Drop the spare capacity the parse's pushes grew, once the parse is over and the log is kept beside its tree. */
	public function seal(): Void {
		_pairs = _pairs.copy();
	}

	/** Push every pair of `pairs`, as `between` or `pairs` returned them. */
	public function replay(pairs: Array<Int>): Void {
		var at: Int = 0;
		while (at + 1 < pairs.length) {
			push(pairs[at], pairs[at + 1]);
			at += 2;
		}
	}

}

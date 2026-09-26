package anyparse.query;

/**
 * Where an offset of a text stands in an earlier version of it: a line diff of the two (Myers, over whole lines), and
 * inside a changed line that has one counterpart the characters its common prefix and suffix keep. An offset in text the
 * change rewrote has no counterpart. Built for a SPARSE change — annotations and small rewrites a `--fix` pass makes —
 * and gives up past `MAX_EDITS` changed lines, answering no counterpart for anything the common prefix and suffix do not
 * hold.
 */
@:nullSafety(Strict)
final class TextMap {

	/** The most changed lines the diff looks for before it gives up. */
	private static inline final MAX_EDITS: Int = 512;

	private final _beforeStarts: Array<Int>;
	private final _afterStarts: Array<Int>;
	private final _before: Array<String>;
	private final _after: Array<String>;

	/** After-line index -> the before-line it is equal to, or -1. */
	private final _match: Array<Int>;

	private function new(before: String, after: String) {
		_before = lines(before);
		_after = lines(after);
		_beforeStarts = starts(_before);
		_afterStarts = starts(_after);
		_match = [for (_ in 0..._after.length) -1];
	}

	/** The map from `after` back to `before`. */
	public static function between(before: String, after: String): TextMap {
		final map: TextMap = new TextMap(before, after);
		map.align();
		return map;
	}

	/** The offset of `before` the offset `at` of `after` stands for, or -1 when it lies in text the change rewrote. */
	public function toBefore(at: Int): Int {
		final line: Int = lineOf(_afterStarts, at);
		final col: Int = at - _afterStarts[line];
		final same: Int = _match[line];
		if (same >= 0) return _beforeStarts[same] + col;
		final counterpart: Int = counterpartOf(line);
		if (counterpart < 0) return -1;
		final was: String = _before[counterpart];
		final now: String = _after[line];
		final prefix: Int = commonPrefix(was, now);
		if (col <= prefix) return _beforeStarts[counterpart] + col;
		final suffix: Int = commonSuffix(was, now, prefix);
		return col >= now.length - suffix ? _beforeStarts[counterpart] + was.length - (now.length - col) : -1;
	}

	/**
	 * The before-line an unmatched after-line replaced when its run of changed lines replaced a run of as many before-lines;
	 * -1 otherwise.
	 */
	private function counterpartOf(line: Int): Int {
		var first: Int = line;
		while (first > 0 && _match[first - 1] < 0) first--;
		var end: Int = line;
		while (end < _after.length && _match[end] < 0) end++;
		final beforeFrom: Int = first == 0 ? 0 : _match[first - 1] + 1;
		final beforeTo: Int = end == _after.length ? _before.length : _match[end];
		return beforeTo - beforeFrom == end - first ? beforeFrom + (line - first) : -1;
	}

	/** Fill `_match` with the equal lines of a shortest edit script. */
	private function align(): Void {
		var head: Int = 0;
		while (head < _before.length && head < _after.length && _before[head] == _after[head]) {
			_match[head] = head;
			head++;
		}
		var tail: Int = 0;
		while (
			tail < _before.length - head && tail < _after.length - head
			&& _before[_before.length - 1 - tail] == _after[_after.length - 1 - tail]
		) {
			_match[_after.length - 1 - tail] = _before.length - 1 - tail;
			tail++;
		}
		myers(head, _before.length - tail, head, _after.length - tail);
	}

	/** Myers' shortest edit script over before-lines `[a0, a1)` and after-lines `[b0, b1)`, recording its equal lines. */
	private function myers(a0: Int, a1: Int, b0: Int, b1: Int): Void {
		final n: Int = a1 - a0;
		final m: Int = b1 - b0;
		if (n == 0 || m == 0) return;
		// diagonal k lives at `n + m + 1 + k`: every k the search reaches, and its neighbours, stay in range
		final at: Int = n + m + 1;
		final trace: Array<Array<Int>> = [];
		if (!search(a0, b0, n, m, at, trace)) return;
		var x: Int = n;
		var y: Int = m;
		var step: Int = trace.length - 1;
		while (step >= 0) {
			final back: Array<Int> = trace[step];
			final k: Int = x - y;
			final prevK: Int = k == -step || (k != step && back[at + k - 1] < back[at + k + 1]) ? k + 1 : k - 1;
			final prevX: Int = back[at + prevK];
			final prevY: Int = prevX - prevK;
			while (x > prevX && y > prevY) {
				x--;
				y--;
				_match[b0 + y] = a0 + x;
			}
			x = prevX;
			y = prevY;
			step--;
		}
	}

	/**
	 * The forward half of `myers`: extend every diagonal one edit at a time until one reaches `(n, m)`, pushing onto
	 * `trace` the furthest reach of each diagonal before each round. False when that takes more than `MAX_EDITS` edits.
	 */
	private function search(a0: Int, b0: Int, n: Int, m: Int, at: Int, trace: Array<Array<Int>>): Bool {
		final v: Array<Int> = [for (_ in 0...2 * at + 1) 0];
		for (d in 0...Std.int(Math.min(n + m, MAX_EDITS)) + 1) {
			trace.push(v.copy());
			var k: Int = -d;
			while (k <= d) {
				var x: Int = k == -d || (k != d && v[at + k - 1] < v[at + k + 1]) ? v[at + k + 1] : v[at + k - 1] + 1;
				var y: Int = x - k;
				while (x < n && y < m && _before[a0 + x] == _after[b0 + y]) {
					x++;
					y++;
				}
				v[at + k] = x;
				if (x >= n && y >= m) return true;
				k += 2;
			}
		}
		return false;
	}

	/** `text` cut into lines, each keeping its line break. */
	private static function lines(text: String): Array<String> {
		final out: Array<String> = [];
		var from: Int = 0;
		while (from < text.length) {
			final nl: Int = text.indexOf('\n', from);
			final to: Int = nl < 0 ? text.length : nl + 1;
			out.push(text.substring(from, to));
			from = to;
		}
		out.push('');
		return out;
	}

	private static function starts(lines: Array<String>): Array<Int> {
		final out: Array<Int> = [];
		var at: Int = 0;
		for (l in lines) {
			out.push(at);
			at += l.length;
		}
		return out;
	}

	/** The index of the line `at` lies on: the last whose start is at or before it. */
	private static function lineOf(lineStarts: Array<Int>, at: Int): Int {
		var lo: Int = 0;
		var hi: Int = lineStarts.length - 1;
		while (lo < hi) {
			final mid: Int = (lo + hi + 1) >> 1;
			if (lineStarts[mid] <= at)
				lo = mid;
			else
				hi = mid - 1;
		}
		return lo;
	}

	private static function commonPrefix(a: String, b: String): Int {
		var i: Int = 0;
		while (i < a.length && i < b.length && StringTools.fastCodeAt(a, i) == StringTools.fastCodeAt(b, i)) i++;
		return i;
	}

	/** The common suffix of `a` and `b` that does not reach into their first `prefix` characters. */
	private static function commonSuffix(a: String, b: String, prefix: Int): Int {
		var i: Int = 0;
		while (
			i < a.length - prefix && i < b.length - prefix
			&& StringTools.fastCodeAt(a, a.length - 1 - i) == StringTools.fastCodeAt(b, b.length - 1 - i)
		)
			i++;
		return i;
	}

}

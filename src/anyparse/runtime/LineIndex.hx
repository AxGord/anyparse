package anyparse.runtime;

import anyparse.runtime.Span.Position;

using StringTools;

/**
 * Prefix index of the line-start offsets of one source text: resolves an
 * offset to a 1-indexed `{line, col}` by binary search over those starts,
 * where `Span.lineCol` walks the source from zero on every call. A caller
 * that resolves many offsets in the same text pays one linear pass instead
 * of one per lookup.
 *
 * Built once per source and discarded with it — an instance owns nothing
 * but its own array and is immutable after construction, so sharing one
 * across callers needs no coordination. `lineColAt` is exactly equivalent
 * to `Span.lineCol`, including both clamps: an offset past the end of the
 * source resolves to one past the last character, a negative offset to
 * `1:1`.
 */
@:nullSafety(Strict)
final class LineIndex {

	private final _sourceLength: Int;
	private final _lineStarts: Array<Int>;

	public function new(source: String) {
		final starts: Array<Int> = [0];
		final n: Int = source.length;
		for (i in 0...n) if (source.fastCodeAt(i) == '\n'.code) starts.push(i + 1);
		_sourceLength = n;
		_lineStarts = starts;
	}

	/**
	 * Resolve `offset` to a 1-indexed line and column within the indexed
	 * source.
	 */
	public function lineColAt(offset: Int): Position {
		final end: Int = offset < 0 ? 0 : (offset < _sourceLength ? offset : _sourceLength);
		var lo: Int = 0;
		var hi: Int = _lineStarts.length - 1;
		while (lo < hi) {
			final mid: Int = lo + ((hi - lo + 1) >> 1);
			if (_lineStarts[mid] <= end)
				lo = mid;
			else
				hi = mid - 1;
		}
		return { line: lo + 1, col: end - _lineStarts[lo] + 1 };
	}

}

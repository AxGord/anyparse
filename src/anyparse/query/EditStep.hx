package anyparse.query;

import anyparse.runtime.Span;

/** One rewrite an `EditJournal` recorded: `edits` spliced into `before`, settled by the writer as `after`. */
@:nullSafety(Strict)
final class EditStep {

	public final after: String;
	public final key: String;

	private final _before: String;
	private final _edits: Array<{ span: Span, text: String }>;

	/** The splice of `_edits` into `_before`, and its non-whitespace positions, built on first need; null until then. */
	private var _splice: Null<{ solid: Array<Int>, settled: Array<Int> }> = null;

	/** Whether the settled text differs from the splice in more than whitespace; decided with `_splice`. */
	private var _opaque: Bool = false;

	public function new(before: String, edits: Array<{ span: Span, text: String }>, after: String, key: String) {
		_before = before;
		_edits = edits;
		this.after = after;
		this.key = key;
	}

	/**
	 * `span` of `after` in `_before`, or null when it has no counterpart: its ends are carried from the settled text to the
	 * splice by their non-whitespace characters, then back over the edits, none of which may meet the span's interior.
	 */
	public function back(span: Span): Null<Span> {
		final splice: Null<{ solid: Array<Int>, settled: Array<Int> }> = alignment();
		if (splice == null) return null;
		final first: Int = firstSolidAtOrAfter(splice.settled, span.from);
		final last: Int = lastSolidBefore(splice.settled, span.to);
		if (first < 0 || last < first) return null;
		final from: Int = splice.solid[first];
		final to: Int = splice.solid[last] + 1;
		var shift: Int = 0;
		var at: Int = 0;
		for (e in _edits) {
			final start: Int = e.span.from + shift;
			final end: Int = start + e.text.length;
			// an edit meeting the span's interior — text inserted in it, or text deleted from it — leaves no counterpart
			if (start < to && from < end) return null;
			if (end <= from) at = shift + e.text.length - (e.span.to - e.span.from);
			shift += e.text.length - (e.span.to - e.span.from);
		}
		return new Span(from - at, to - at);
	}

	/** The non-whitespace positions of the splice and of the settled text, or null when the two differ in more than whitespace. */
	private function alignment(): Null<{ solid: Array<Int>, settled: Array<Int> }> {
		final held: Null<{ solid: Array<Int>, settled: Array<Int> }> = _splice;
		if (held != null || _opaque) return held;
		final spliced: String = CanonicalEdit.applyEdits(_before, _edits);
		final solid: Array<Int> = solidPositions(spliced);
		final settled: Array<Int> = solidPositions(after);
		var same: Bool = solid.length == settled.length;
		var i: Int = 0;
		while (same && i < solid.length) {
			same = StringTools.fastCodeAt(spliced, solid[i]) == StringTools.fastCodeAt(after, settled[i]);
			i++;
		}
		if (!same) {
			_opaque = true;
			return null;
		}
		final made: { solid: Array<Int>, settled: Array<Int> } = { solid: solid, settled: settled };
		_splice = made;
		return made;
	}

	private static function solidPositions(text: String): Array<Int> {
		return [for (i in 0...text.length) if (!StringTools.isSpace(text, i)) i];
	}

	/** The index in `positions` of the first position at or after `at`, or -1. */
	private static function firstSolidAtOrAfter(positions: Array<Int>, at: Int): Int {
		var lo: Int = 0;
		var hi: Int = positions.length;
		while (lo < hi) {
			final mid: Int = (lo + hi) >> 1;
			if (positions[mid] < at)
				lo = mid + 1;
			else
				hi = mid;
		}
		return lo < positions.length ? lo : -1;
	}

	/** The index in `positions` of the last position before `at`, or -1. */
	private static function lastSolidBefore(positions: Array<Int>, at: Int): Int {
		final next: Int = firstSolidAtOrAfter(positions, at);
		return (next < 0 ? positions.length : next) - 1;
	}

}

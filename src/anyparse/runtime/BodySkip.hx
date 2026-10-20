package anyparse.runtime;

/**
 * What one conditional-compilation directive does to the branch structure a skipped body must keep balanced
 * (`BodySkip.closeAt`): opens a region, starts its next branch, closes it, or branches nothing.
 */
enum abstract SkipMarkRole(Int) {

	final Open = 0;
	final Next = 1;
	final Close = 2;
	final Other = 3;

}

/** One conditional-compilation directive of the source `[from, to)` and what it does to the branch structure. */
typedef SkipMark = {
	final from: Int;
	final to: Int;
	final role: SkipMarkRole;
};

/**
 * The DECLARATIONS-ONLY read of a parse: a generated star field marked `@:skimmable` (a function body's statements)
 * whose `@:lead` / `@:trail` are single characters is not parsed element by element when the parse context carries
 * one of these — the parser jumps from just inside the opening delimiter to its matching close and leaves the list
 * empty. Everything else (declarations, member signatures, initializers) is parsed exactly as without it, so a
 * declaration read off such a tree is the one a full parse gives, at a fraction of the cost: function bodies are
 * most of a module's text.
 *
 * Grammar-agnostic: the code gaps (`gaps`: comments, string and regex literals) come from the grammar's own lexer
 * and the directives (`marks`) from its declared conditional-compilation vocabulary, so no character class of any
 * language is spelled here; the delimiters are the grammar's `@:lead` / `@:trail`. A run the balancing cannot prove
 * — the delimiters do not match, a directive branch does not return to the depth it opened at, a region opened in the
 * run is still open at its end, or the input ends — is NOT skipped: `closeAt` answers the position it was given and
 * the generated parser reads the body element by element, exactly as a full parse would.
 */
@:nullSafety(Strict)
final class BodySkip {

	/** Non-code regions of the input, `[from, to)`, in source order. */
	private final _gaps: Array<Span>;

	/** Conditional-compilation directives of the input, in source order, none inside a gap. */
	private final _marks: Array<SkipMark>;

	public function new(gaps: Array<Span>, marks: Array<SkipMark>) {
		_gaps = gaps;
		_marks = marks;
	}

	/**
	 * The offset of the `close` character that ends the run opened just before `pos` — balanced against `open`
	 * outside every gap, with every directive region opened in the run closed in it and each of its branches back at
	 * the depth the region opened at. `pos` itself when the run cannot be proven so.
	 */
	public function closeAt(input: Input, pos: Int, open: Int, close: Int): Int {
		var gap: Int = firstEndingAfter(pos);
		var mark: Int = firstMarkFrom(pos);
		final opened: Array<Int> = [];
		var depth: Int = 0;
		var i: Int = pos;
		final length: Int = input.length;
		while (i < length) {
			if (gap < _gaps.length && i >= _gaps[gap].from) {
				if (i < _gaps[gap].to) i = _gaps[gap].to;
				gap++;
				continue;
			}
			if (mark < _marks.length && i >= _marks[mark].from) {
				final m: SkipMark = _marks[mark];
				mark++;
				switch m.role {
					case Open:
						opened.push(depth);
					case Next, Close:
						if (opened.length == 0 || opened[opened.length - 1] != depth) return pos;
						if (m.role == Close) opened.pop();
					case Other:
				}
				if (i < m.to) i = m.to;
				continue;
			}
			final c: Int = input.charCodeAt(i);
			if (c == close) {
				if (depth == 0) return opened.length == 0 ? i : pos;
				depth--;
			} else if (c == open) {
				depth++;
			}
			i++;
		}
		return pos;
	}

	/** The index of the first gap that ends after `pos`. */
	private function firstEndingAfter(pos: Int): Int {
		var low: Int = 0;
		var high: Int = _gaps.length;
		while (low < high) {
			final middle: Int = (low + high) >> 1;
			if (_gaps[middle].to <= pos)
				low = middle + 1
			else
				high = middle;
		}
		return low;
	}

	/** The index of the first directive that starts at or after `pos`. */
	private function firstMarkFrom(pos: Int): Int {
		var low: Int = 0;
		var high: Int = _marks.length;
		while (low < high) {
			final middle: Int = (low + high) >> 1;
			if (_marks[middle].from < pos)
				low = middle + 1
			else
				high = middle;
		}
		return low;
	}

}

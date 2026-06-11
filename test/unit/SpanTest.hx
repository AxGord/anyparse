package unit;

import utest.Assert;
import utest.Test;
import anyparse.runtime.Span;

/**
 * Tests for `Span` — zero-width construction, `toString` shape, and
 * `lineCol` resolution across line-boundary edge cases.
 */
class SpanTest extends Test {

	function testZeroWidthSpanToString() {
		Assert.equals('7', new Span(7, 7).toString());
	}

	function testRangeSpanToString() {
		Assert.equals('3..10', new Span(3, 10).toString());
	}

	function testLineColAtStart() {
		final s: Span = new Span(0, 0);
		final p: { line: Int, col: Int } = s.lineCol('hello\nworld');
		Assert.equals(1, p.line);
		Assert.equals(1, p.col);
	}

	function testLineColMidFirstLine() {
		final s: Span = new Span(3, 3);
		final p: { line: Int, col: Int } = s.lineCol('hello\nworld');
		Assert.equals(1, p.line);
		Assert.equals(4, p.col);
	}

	function testLineColAtNewline() {
		final s: Span = new Span(5, 5);
		final p: { line: Int, col: Int } = s.lineCol('hello\nworld');
		Assert.equals(1, p.line);
		Assert.equals(6, p.col);
	}

	function testLineColAfterNewline() {
		final s: Span = new Span(6, 6);
		final p: { line: Int, col: Int } = s.lineCol('hello\nworld');
		Assert.equals(2, p.line);
		Assert.equals(1, p.col);
	}

	function testLineColMidSecondLine() {
		final s: Span = new Span(8, 8);
		final p: { line: Int, col: Int } = s.lineCol('hello\nworld');
		Assert.equals(2, p.line);
		Assert.equals(3, p.col);
	}

	function testLineColMultipleNewlines() {
		final s: Span = new Span(4, 4);
		final p: { line: Int, col: Int } = s.lineCol('a\nb\nc\nd');
		Assert.equals(3, p.line);
		Assert.equals(1, p.col);
	}

	function testLineColPastEnd() {
		final s: Span = new Span(100, 100);
		final p: { line: Int, col: Int } = s.lineCol('hello\nworld');
		Assert.equals(2, p.line);
		Assert.equals(6, p.col);
	}

	function testLineColEmptySource() {
		final s: Span = new Span(0, 0);
		final p: { line: Int, col: Int } = s.lineCol('');
		Assert.equals(1, p.line);
		Assert.equals(1, p.col);
	}

	function testOffsetOfStart() {
		Assert.equals(0, Span.offsetOf('hello\nworld', 1, 1));
	}

	function testOffsetOfMidFirstLine() {
		Assert.equals(3, Span.offsetOf('hello\nworld', 1, 4));
	}

	function testOffsetOfAfterNewline() {
		Assert.equals(6, Span.offsetOf('hello\nworld', 2, 1));
	}

	function testOffsetOfMidSecondLine() {
		Assert.equals(8, Span.offsetOf('hello\nworld', 2, 3));
	}

	function testOffsetOfMultipleNewlines() {
		Assert.equals(4, Span.offsetOf('a\nb\nc\nd', 3, 1));
	}

	function testOffsetOfColPastLineEndClampsToNewline() {
		// col beyond line 1 content → clamp to the newline offset (5).
		Assert.equals(5, Span.offsetOf('hello\nworld', 1, 99));
	}

	function testOffsetOfLinePastEndClampsToSourceLength() {
		Assert.equals(11, Span.offsetOf('hello\nworld', 99, 1));
	}

	function testOffsetOfEmptySource() {
		Assert.equals(0, Span.offsetOf('', 1, 1));
	}

	function testOffsetOfNonPositiveIsZero() {
		Assert.equals(0, Span.offsetOf('hello', 0, 1));
		Assert.equals(0, Span.offsetOf('hello', 1, 0));
	}

	function testOffsetOfRoundTripsLineCol() {
		// offsetOf is the inverse of lineCol for in-range offsets.
		final source: String = 'abc\nde\nfghi';
		for (off in [0, 1, 3, 4, 6, 7, 10]) {
			final p: { line: Int, col: Int } = new Span(off, off).lineCol(source);
			Assert.equals(off, Span.offsetOf(source, p.line, p.col), 'round-trip failed at offset $off');
		}
	}

	function testFieldsImmutable() {
		final s: Span = new Span(2, 5);
		Assert.equals(2, s.from);
		Assert.equals(5, s.to);
	}

}

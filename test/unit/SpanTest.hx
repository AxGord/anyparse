package unit;

import utest.Assert;
import utest.Test;
import anyparse.runtime.Span;
import anyparse.runtime.LineIndex;

/**
 * Tests for `Span` — zero-width construction, `toString` shape, and
 * `lineCol` resolution across line-boundary edge cases, plus the parity
 * contract that `LineIndex.lineColAt` resolves every offset exactly as
 * `Span.lineCol` does.
 */
class SpanTest extends Test {

	private function testZeroWidthSpanToString(): Void {
		Assert.equals('7', new Span(7, 7).toString());
	}

	private function testRangeSpanToString(): Void {
		Assert.equals('3..10', new Span(3, 10).toString());
	}

	private function testLineColAtStart(): Void {
		final s: Span = new Span(0, 0);
		final p: { line: Int, col: Int } = s.lineCol('hello\nworld');
		Assert.equals(1, p.line);
		Assert.equals(1, p.col);
	}

	private function testLineColMidFirstLine(): Void {
		final s: Span = new Span(3, 3);
		final p: { line: Int, col: Int } = s.lineCol('hello\nworld');
		Assert.equals(1, p.line);
		Assert.equals(4, p.col);
	}

	private function testLineColAtNewline(): Void {
		final s: Span = new Span(5, 5);
		final p: { line: Int, col: Int } = s.lineCol('hello\nworld');
		Assert.equals(1, p.line);
		Assert.equals(6, p.col);
	}

	private function testLineColAfterNewline(): Void {
		final s: Span = new Span(6, 6);
		final p: { line: Int, col: Int } = s.lineCol('hello\nworld');
		Assert.equals(2, p.line);
		Assert.equals(1, p.col);
	}

	private function testLineColMidSecondLine(): Void {
		final s: Span = new Span(8, 8);
		final p: { line: Int, col: Int } = s.lineCol('hello\nworld');
		Assert.equals(2, p.line);
		Assert.equals(3, p.col);
	}

	private function testLineColMultipleNewlines(): Void {
		final s: Span = new Span(4, 4);
		final p: { line: Int, col: Int } = s.lineCol('a\nb\nc\nd');
		Assert.equals(3, p.line);
		Assert.equals(1, p.col);
	}

	private function testLineColPastEnd(): Void {
		final s: Span = new Span(100, 100);
		final p: { line: Int, col: Int } = s.lineCol('hello\nworld');
		Assert.equals(2, p.line);
		Assert.equals(6, p.col);
	}

	private function testLineColEmptySource(): Void {
		final s: Span = new Span(0, 0);
		final p: { line: Int, col: Int } = s.lineCol('');
		Assert.equals(1, p.line);
		Assert.equals(1, p.col);
	}

	private function testLineColAtCarriageReturn(): Void {
		// \r is an ordinary column-advancing character; only \n breaks the line.
		final source: String = 'a\r\nb';
		Assert.equals(1, new Span(1, 1).lineCol(source).line);
		Assert.equals(2, new Span(1, 1).lineCol(source).col);
		Assert.equals(1, new Span(2, 2).lineCol(source).line);
		Assert.equals(3, new Span(2, 2).lineCol(source).col);
		Assert.equals(2, new Span(3, 3).lineCol(source).line);
		Assert.equals(1, new Span(3, 3).lineCol(source).col);
	}

	private function testLineColAtLastCharacter(): Void {
		final p: Position = new Span(10, 10).lineCol('hello\nworld');
		Assert.equals(2, p.line);
		Assert.equals(5, p.col);
	}

	private function testLineColAtSourceLength(): Void {
		final p: Position = new Span(11, 11).lineCol('hello\nworld');
		Assert.equals(2, p.line);
		Assert.equals(6, p.col);
	}

	private function testLineColAtNegativeOffset(): Void {
		// A negative offset (the shared backtrack sentinel spans -2..-2) resolves to 1:1.
		final p: Position = new Span(-2, -2).lineCol('a\nb');
		Assert.equals(1, p.line);
		Assert.equals(1, p.col);
	}

	private function testLineIndexMatchesLineColAtEveryOffset(): Void {
		for (source in [
			'',
			'a',
			'hello\nworld',
			'a\r\nb\r\nc',
			'\n\n\n',
			'x\ny\n',
			'abc\nde\nfghi',
			'1\n2\n3\n4\n5\n6\n7\n8\n9'
		]) assertIndexParity(source);
	}

	private function testOffsetOfStart(): Void {
		Assert.equals(0, Span.offsetOf('hello\nworld', 1, 1));
	}

	private function testOffsetOfMidFirstLine(): Void {
		Assert.equals(3, Span.offsetOf('hello\nworld', 1, 4));
	}

	private function testOffsetOfAfterNewline(): Void {
		Assert.equals(6, Span.offsetOf('hello\nworld', 2, 1));
	}

	private function testOffsetOfMidSecondLine(): Void {
		Assert.equals(8, Span.offsetOf('hello\nworld', 2, 3));
	}

	private function testOffsetOfMultipleNewlines(): Void {
		Assert.equals(4, Span.offsetOf('a\nb\nc\nd', 3, 1));
	}

	private function testOffsetOfColPastLineEndClampsToNewline(): Void {
		// col beyond line 1 content → clamp to the newline offset (5).
		Assert.equals(5, Span.offsetOf('hello\nworld', 1, 99));
	}

	private function testOffsetOfLinePastEndClampsToSourceLength(): Void {
		Assert.equals(11, Span.offsetOf('hello\nworld', 99, 1));
	}

	private function testOffsetOfEmptySource(): Void {
		Assert.equals(0, Span.offsetOf('', 1, 1));
	}

	private function testOffsetOfNonPositiveIsZero(): Void {
		Assert.equals(0, Span.offsetOf('hello', 0, 1));
		Assert.equals(0, Span.offsetOf('hello', 1, 0));
	}

	private function testOffsetOfRoundTripsLineCol(): Void {
		// offsetOf is the inverse of lineCol for in-range offsets.
		final source: String = 'abc\nde\nfghi';
		for (off in [0, 1, 3, 4, 6, 7, 10]) {
			final p: { line: Int, col: Int } = new Span(off, off).lineCol(source);
			Assert.equals(off, Span.offsetOf(source, p.line, p.col), 'round-trip failed at offset $off');
		}
	}

	private function testFieldsImmutable(): Void {
		final s: Span = new Span(2, 5);
		Assert.equals(2, s.from);
		Assert.equals(5, s.to);
	}

	private static function assertIndexParity(source: String): Void {
		final index: LineIndex = new LineIndex(source);
		for (offset in -3...source.length + 4) {
			final expected: Position = new Span(offset, offset).lineCol(source);
			final actual: Position = index.lineColAt(offset);
			Assert.equals(expected.line, actual.line, 'line mismatch at offset $offset');
			Assert.equals(expected.col, actual.col, 'col mismatch at offset $offset');
		}
	}

}

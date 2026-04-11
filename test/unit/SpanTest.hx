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
		final s:Span = new Span(0, 0);
		final p:{line:Int, col:Int} = s.lineCol('hello\nworld');
		Assert.equals(1, p.line);
		Assert.equals(1, p.col);
	}

	function testLineColMidFirstLine() {
		final s:Span = new Span(3, 3);
		final p:{line:Int, col:Int} = s.lineCol('hello\nworld');
		Assert.equals(1, p.line);
		Assert.equals(4, p.col);
	}

	function testLineColAtNewline() {
		final s:Span = new Span(5, 5);
		final p:{line:Int, col:Int} = s.lineCol('hello\nworld');
		Assert.equals(1, p.line);
		Assert.equals(6, p.col);
	}

	function testLineColAfterNewline() {
		final s:Span = new Span(6, 6);
		final p:{line:Int, col:Int} = s.lineCol('hello\nworld');
		Assert.equals(2, p.line);
		Assert.equals(1, p.col);
	}

	function testLineColMidSecondLine() {
		final s:Span = new Span(8, 8);
		final p:{line:Int, col:Int} = s.lineCol('hello\nworld');
		Assert.equals(2, p.line);
		Assert.equals(3, p.col);
	}

	function testLineColMultipleNewlines() {
		final s:Span = new Span(4, 4);
		final p:{line:Int, col:Int} = s.lineCol('a\nb\nc\nd');
		Assert.equals(3, p.line);
		Assert.equals(1, p.col);
	}

	function testLineColPastEnd() {
		final s:Span = new Span(100, 100);
		final p:{line:Int, col:Int} = s.lineCol('hello\nworld');
		Assert.equals(2, p.line);
		Assert.equals(6, p.col);
	}

	function testLineColEmptySource() {
		final s:Span = new Span(0, 0);
		final p:{line:Int, col:Int} = s.lineCol('');
		Assert.equals(1, p.line);
		Assert.equals(1, p.col);
	}

	function testFieldsImmutable() {
		final s:Span = new Span(2, 5);
		Assert.equals(2, s.from);
		Assert.equals(5, s.to);
	}
}

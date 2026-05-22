package unit;

import utest.Assert;
import utest.Test;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import anyparse.runtime.Severity;

/**
 * Tests for `ParseError` — construction, defaults, throwability, and
 * the shape of its human-readable `toString` output.
 */
class ParseErrorTest extends Test {

	function testDefaultSeverityIsError() {
		final e:ParseError = new ParseError(new Span(0, 0), 'bad');
		Assert.equals(Severity.Error, e.severity);
	}

	function testExpectedIsOptional() {
		final e:ParseError = new ParseError(new Span(0, 0), 'bad');
		Assert.isNull(e.expected);
	}

	function testPreservesSpanAndMessage() {
		final e:ParseError = new ParseError(new Span(10, 15), 'broken');
		Assert.equals(10, e.span.from);
		Assert.equals(15, e.span.to);
		Assert.equals('broken', e.message);
	}

	function testToStringBasicError() {
		final e:ParseError = new ParseError(new Span(4, 4), 'unexpected character');
		Assert.equals('error at 4: unexpected character', e.toString());
	}

	function testToStringWithRange() {
		final e:ParseError = new ParseError(new Span(4, 9), 'bad token');
		Assert.equals('error at 4..9: bad token', e.toString());
	}

	function testToStringWithExpected() {
		final e:ParseError = new ParseError(new Span(2, 2), 'missing bracket', ']');
		Assert.equals('error at 2: missing bracket (expected ])', e.toString());
	}

	function testToStringWarningSeverity() {
		final e:ParseError = new ParseError(new Span(0, 0), 'deprecated syntax', null, Severity.Warning);
		Assert.equals('warning at 0: deprecated syntax', e.toString());
	}

	function testIsThrowable() {
		Assert.raises(() -> {
			throw new ParseError(new Span(0, 0), 'boom');
		}, ParseError);
	}

	// -- `source` decoration: when attached, `toString` renders 1-indexed
	// line:col via `Span.lineCol(source)` instead of the raw byte offset.

	function testToStringWithSourceUsesLineCol() {
		final src:String = 'class C {\n\tvar x:\n}';
		final e:ParseError = new ParseError(new Span(17, 17), 'unexpected input');
		e.source = src;
		Assert.equals('error at 2:8: unexpected input', e.toString());
	}

	function testToStringWithSourceAndExpected() {
		final src:String = 'class C {\n\tvar x:\n}';
		final e:ParseError = new ParseError(new Span(17, 17), 'unexpected input', '//');
		e.source = src;
		Assert.equals('error at 2:8: unexpected input (expected //)', e.toString());
	}

	function testToStringWithoutSourceFallsBackToByteOffset() {
		// `source` is null by default — pre-existing toString shape stays
		// in effect for direct callers that don't attach the source.
		final e:ParseError = new ParseError(new Span(17, 17), 'unexpected input');
		Assert.equals('error at 17: unexpected input', e.toString());
		Assert.isNull(e.source);
	}

	function testSourceIsMutableAfterConstruction() {
		// The entry-point decorator attaches `source` post-construction,
		// so the field must be settable on a thrown-and-caught error.
		final e:ParseError = new ParseError(new Span(0, 0), 'boom');
		Assert.isNull(e.source);
		e.source = 'class X {}';
		Assert.equals('class X {}', e.source);
	}
}

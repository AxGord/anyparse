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
}

package unit;

import utest.Assert;
import utest.Test;
import anyparse.runtime.Input;
import anyparse.runtime.StringInput;

/**
 * Smoke tests for the `Input` abstraction via `StringInput`.
 *
 * Ensures the out-of-bounds sentinel contract is honoured: callers
 * rely on `charCodeAt` returning `-1` past the ends of the input
 * rather than a `null` or throwing.
 */
class InputTest extends Test {

	function testLengthMatchesSource() {
		final inp:Input = new StringInput('hello');
		Assert.equals(5, inp.length);
	}

	function testLengthEmptySource() {
		final inp:Input = new StringInput('');
		Assert.equals(0, inp.length);
	}

	function testCharCodeAtFirst() {
		final inp:Input = new StringInput('abc');
		Assert.equals('a'.code, inp.charCodeAt(0));
	}

	function testCharCodeAtLast() {
		final inp:Input = new StringInput('abc');
		Assert.equals('c'.code, inp.charCodeAt(2));
	}

	function testCharCodeAtNegative() {
		final inp:Input = new StringInput('abc');
		Assert.equals(-1, inp.charCodeAt(-1));
	}

	function testCharCodeAtPastEnd() {
		final inp:Input = new StringInput('abc');
		Assert.equals(-1, inp.charCodeAt(3));
		Assert.equals(-1, inp.charCodeAt(999));
	}

	function testSubstringFull() {
		final inp:Input = new StringInput('hello');
		Assert.equals('hello', inp.substring(0, 5));
	}

	function testSubstringMiddle() {
		final inp:Input = new StringInput('hello world');
		Assert.equals('llo w', inp.substring(2, 7));
	}

	function testSubstringEmpty() {
		final inp:Input = new StringInput('abc');
		Assert.equals('', inp.substring(1, 1));
	}
}

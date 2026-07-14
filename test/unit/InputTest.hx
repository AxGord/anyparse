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

	private function testLengthMatchesSource(): Void {
		final inp: Input = new StringInput('hello');
		Assert.equals(5, inp.length);
	}

	private function testLengthEmptySource(): Void {
		final inp: Input = new StringInput('');
		Assert.equals(0, inp.length);
	}

	private function testCharCodeAtFirst(): Void {
		final inp: Input = new StringInput('abc');
		Assert.equals('a'.code, inp.charCodeAt(0));
	}

	private function testCharCodeAtLast(): Void {
		final inp: Input = new StringInput('abc');
		Assert.equals('c'.code, inp.charCodeAt(2));
	}

	private function testCharCodeAtNegative(): Void {
		final inp: Input = new StringInput('abc');
		Assert.equals(-1, inp.charCodeAt(-1));
	}

	private function testCharCodeAtPastEnd(): Void {
		final inp: Input = new StringInput('abc');
		Assert.equals(-1, inp.charCodeAt(3));
		Assert.equals(-1, inp.charCodeAt(999));
	}

	private function testSubstringFull(): Void {
		final inp: Input = new StringInput('hello');
		Assert.equals('hello', inp.substring(0, 5));
	}

	private function testSubstringMiddle(): Void {
		final inp: Input = new StringInput('hello world');
		Assert.equals('llo w', inp.substring(2, 7));
	}

	private function testSubstringEmpty(): Void {
		final inp: Input = new StringInput('abc');
		Assert.equals('', inp.substring(1, 1));
	}

}

package unit.runtime;

import anyparse.runtime.AnchoredRegex;
import anyparse.runtime.BytesInput;
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

	/** A pattern built by `AnchoredRegex.of` matches only where it is tried, every alternative included. */
	private function testMatchAtAnchorsEveryAlternative(): Void {
		final re: EReg = AnchoredRegex.of('b|c');
		final inp: Input = new StringInput('abc');
		Assert.isFalse(inp.matchAt(re, 0));
		Assert.isTrue(inp.matchAt(re, 1));
		Assert.equals('b', re.matched(0));
		Assert.isTrue(inp.matchAt(re, 2));
		Assert.equals('c', re.matched(0));
		Assert.isFalse(inp.matchAt(re, 3));
	}

	private function testBytesInputMatchesAtAnOffset(): Void {
		final re: EReg = AnchoredRegex.of('[0-9]+');
		final inp: Input = new BytesInput(haxe.io.Bytes.ofString('ab12c'));
		Assert.isFalse(inp.matchAt(re, 1));
		Assert.isTrue(inp.matchAt(re, 2));
		Assert.equals('12', re.matched(0));
	}

}

package unit.query;

import anyparse.query.CodepointIndex;
import utest.Assert;
import utest.Test;

/** `CodepointIndex`: codepoint offsets, as the compiler reports them, against the target's own string offsets. */
@:nullSafety(Strict)
class CodepointIndexTest extends Test {

	@:pin('control') @:killer('M-CODEPOINT-NATIVE') @:killer('M-CODEPOINT-BACK')
	public function testAWideCodepointCountsTwoNativeUnits(): Void {
		// Cyrillic is one unit on every target; an emoji is a surrogate pair where strings count UTF-16 units
		final source: String = 'ab ёж 😀x😀 y';
		final index: CodepointIndex = CodepointIndex.of(source);
		final wide: Int = source.length - codepoints(source);
		for (cp in 0...codepoints(source) + 1) {
			final native: Int = index.toNative(cp);
			Assert.equals(cp, index.toCodepoint(native), 'codepoint $cp does not round-trip');
		}
		final y: Int = source.indexOf('y');
		Assert.equals(y, index.toNative(y - wide));
		Assert.equals(y - wide, index.toCodepoint(y));
		Assert.equals(source.indexOf('x'), index.toNative(source.indexOf('x') - wide + 1));
	}

	public function testAnAsciiOrBmpTextMapsToItself(): Void {
		final index: CodepointIndex = CodepointIndex.of('class Привет {}');
		for (i in 0...16) Assert.equals(i, index.toNative(i));
	}

	/** The codepoints of `s`. */
	private static function codepoints(s: String): Int {
		var n: Int = 0;
		for (_ in new haxe.iterators.StringIteratorUnicode(s)) n++;
		return n;
	}

}

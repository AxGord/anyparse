package anyparse.ds;

import haxe.ds.Vector;

/**
 * Word arithmetic of a bit set wider than one `Int`: bit `i` lives in word `i >>> SHIFT` at position `i & LAST`.
 * No operation changes its operands.
 */
final class BitWords {

	/** How far a bit index shifts right to name its word. */
	public static inline final SHIFT: Int = 5;

	/** The highest position in a word, and the mask that keeps a bit index's position. */
	public static inline final LAST: Int = 31;

	private static inline final HALF: Int = 16;

	/**
	 * The position of the lowest bit set in `word`, which is not 0. The portable path never negates or decrements
	 * `word`: on hxcpp that overflows a signed int at bit 31.
	 */
	public static inline function lowest(word: Int): Int {
		#if js
		return LAST - js.lib.Math.clz32(word & -word);
		#else
		var position: Int = 0;
		var rest: Int = word;
		var span: Int = HALF;
		while (span > 0) {
			if ((rest & ((1 << span) - 1)) == 0) {
				position += span;
				rest >>>= span;
			}
			span >>= 1;
		}
		return position;
		#end
	}

	public static inline function has(words: Vector<Int>, bit: Int): Bool {
		return (words[bit >>> SHIFT] & (1 << (bit & LAST))) != 0;
	}

	/** `count` words, every bit clear. */
	public static function make(count: Int): Vector<Int> {
		final words: Vector<Int> = new Vector<Int>(count);
		for (index in 0...count) words[index] = 0;
		return words;
	}

	/** A copy of `words` with `bit` set. */
	public static function with(words: Vector<Int>, bit: Int): Vector<Int> {
		final next: Vector<Int> = words.copy();
		next[bit >>> SHIFT] |= 1 << (bit & LAST);
		return next;
	}

	/** A copy of `words` with `bit` clear. */
	public static function without(words: Vector<Int>, bit: Int): Vector<Int> {
		final next: Vector<Int> = words.copy();
		next[bit >>> SHIFT] &= ~(1 << (bit & LAST));
		return next;
	}

	public static function isEmpty(words: Vector<Int>): Bool {
		for (index in 0...words.length) if (words[index] != 0) return false;
		return true;
	}

	public static function or(left: Vector<Int>, right: Vector<Int>): Vector<Int> {
		final next: Vector<Int> = new Vector<Int>(left.length);
		for (index in 0...left.length) next[index] = left[index] | right[index];
		return next;
	}

	public static function and(left: Vector<Int>, right: Vector<Int>): Vector<Int> {
		final next: Vector<Int> = new Vector<Int>(left.length);
		for (index in 0...left.length) next[index] = left[index] & right[index];
		return next;
	}

	/** Every bit of `full` that `words` does not hold. */
	public static function complement(words: Vector<Int>, full: Array<Int>): Vector<Int> {
		final next: Vector<Int> = new Vector<Int>(words.length);
		for (index in 0...words.length) next[index] = ~words[index] & full[index];
		return next;
	}

	public static function same(left: Vector<Int>, right: Vector<Int>): Bool {
		for (index in 0...left.length) if (left[index] != right[index]) return false;
		return true;
	}

}

package anyparse.query;

/**
 * The map between two ways of counting a position in one source text: in codepoints, which is how the Haxe compiler
 * reports `Position.min`/`max`, and in the target's own string units, which is what an anyparse `Span` counts — UTF-16
 * code units on nodejs and the JVM. The two differ by one for every codepoint outside the Basic Multilingual Plane (an
 * emoji) before the position; on a target whose strings count codepoints they are the same.
 */
@:nullSafety(Strict)
final class CodepointIndex {

	/** The UTF-16 high (leading) surrogate range. */
	private static inline final HIGH_FIRST: Int = 0xD800;

	private static inline final HIGH_LAST: Int = 0xDBFF;

	/** The UTF-16 low (trailing) surrogate range. */
	private static inline final LOW_FIRST: Int = 0xDC00;

	private static inline final LOW_LAST: Int = 0xDFFF;

	/** The native offset of each codepoint that takes two native units, ascending. */
	private final _wideNative: Array<Int>;

	/** The same codepoints' codepoint offsets, ascending. */
	private final _wideCodepoint: Array<Int>;

	private function new(wideNative: Array<Int>, wideCodepoint: Array<Int>) {
		this._wideNative = wideNative;
		this._wideCodepoint = wideCodepoint;
	}

	/** The native offset of codepoint offset `codepoint`. */
	public function toNative(codepoint: Int): Int {
		return codepoint + countBelow(_wideCodepoint, codepoint);
	}

	/** The codepoint offset of native offset `native`; an offset inside a surrogate pair counts as the pair's start. */
	public function toCodepoint(native: Int): Int {
		return native - countBelow(_wideNative, native);
	}

	/** The index of `source`. */
	public static function of(source: String): CodepointIndex {
		final wideNative: Array<Int> = [];
		final wideCodepoint: Array<Int> = [];
		#if target.utf16
		var i: Int = 0;
		final end: Int = source.length - 1;
		while (i < end) {
			final unit: Int = StringTools.fastCodeAt(source, i);
			if (unit >= HIGH_FIRST && unit <= HIGH_LAST) {
				final next: Int = StringTools.fastCodeAt(source, i + 1);
				if (next >= LOW_FIRST && next <= LOW_LAST) {
					wideCodepoint.push(i - wideNative.length);
					wideNative.push(i);
					i++;
				}
			}
			i++;
		}
		#end
		return new CodepointIndex(wideNative, wideCodepoint);
	}

	/** How many of the ascending `offsets` are below `limit`. */
	private static function countBelow(offsets: Array<Int>, limit: Int): Int {
		var lo: Int = 0;
		var hi: Int = offsets.length;
		while (lo < hi) {
			final mid: Int = (lo + hi) >> 1;
			if (offsets[mid] < limit)
				lo = mid + 1
			else
				hi = mid;
		}
		return lo;
	}

}

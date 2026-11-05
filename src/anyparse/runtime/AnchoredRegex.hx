package anyparse.runtime;

/**
 * The one answer to "how is a terminal's regex tried at one position of the input".
 *
 * `^` binds a match to offset 0, so it costs a slice of the rest of the input per try: free on a target whose
 * strings share storage, a copy on the others, which made a parse quadratic in the document on those. A target
 * with `\G` and an offset-taking `matchSub` matches over the input in place instead.
 *
 * Contract of a pattern: it does not look behind its own start. In place a lookbehind or a leading `\b` would read
 * the characters before the position, which a slice does not hold, so the targets would answer differently.
 */
@:nullSafety(Strict)
final class AnchoredRegex {

	/** The assertion pinning a pattern to where it is tried. */
	private static inline final ANCHOR: String = #if (cpp || jvm) '\\G' #else '^' #end;

	/** Whether `re`, built by `of`, matches `source` at offset `pos`. */
	public static inline function matchIn(re: EReg, source: String, pos: Int): Bool {
		return #if (cpp || jvm) re.matchSub(source, pos) #else re.match(source.substring(pos, source.length)) #end;
	}

	/** `pattern` compiled to match only at the position it is tried at; the group holds every alternative under the anchor. */
	public static function of(pattern: String): EReg {
		return new EReg('$ANCHOR(?:$pattern)', '');
	}

}

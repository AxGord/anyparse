package anyparse.check;

using StringTools;

/**
 * Reads a type the way the compiler facts SPELL it (`TypedFactsProbe`: `(Iterable<$f.A>,Int)->Bool`,
 * `Null<pack.T>`). That spelling is the compiler's, not Haxe source — a type parameter prints as
 * `$owner.Name`, which the grammar does not read — so it has its own reader, shared by the probe
 * (macro time) and the checks that consume its output (run time); no dependency, so both can compile it.
 */
@:nullSafety(Strict)
final class FactsTypeText {

	private static inline final NULL_NAME: String = 'Null';

	/**
	 * `type` without the `Null<…>` wrappers that enclose the WHOLE of it — each peeled only while its `<`
	 * closes at the last character. `Null<A> -> Null<B>` is a function type and is returned unchanged.
	 */
	public static function unwrapNull(type: String): String {
		return unwrap(type, [NULL_NAME]);
	}

	/**
	 * `type` without the wrappers named in `wrappers` (`Null`, or any type the caller sees through) that enclose the
	 * WHOLE of it — each peeled only while its `<` closes at the last character, so a function type whose parameter
	 * starts with one is returned unchanged.
	 */
	public static function unwrap(type: String, wrappers: Array<String>): String {
		var out: String = type;
		while (true) {
			final open: Int = out.indexOf('<');
			if (open <= 0 || !wrappers.contains(out.substr(0, open)) || !closesAtEnd(out, open)) return out;
			out = out.substring(open + 1, out.length - 1);
		}
	}

	/** Whether the `<` at `open` in `type` is closed by its last character — the `>` of a `->` arrow closes nothing. */
	private static function closesAtEnd(type: String, open: Int): Bool {
		var depth: Int = 0;
		for (i in open ... type.length) {
			final c: Int = type.fastCodeAt(i);
			if (c == '<'.code) {
				depth++;
			} else if (c == '>'.code && type.fastCodeAt(i - 1) != '-'.code) {
				depth--;
				if (depth == 0) return i == type.length - 1;
			}
		}
		return false;
	}

}

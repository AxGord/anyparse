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

	private static inline final NULL_OPEN: String = 'Null<';

	/**
	 * `type` without the `Null<…>` wrappers that enclose the WHOLE of it — each peeled only while its `<`
	 * closes at the last character. `Null<A> -> Null<B>` is a function type and is returned unchanged.
	 */
	public static function unwrapNull(type: String): String {
		var out: String = type;
		while (out.startsWith(NULL_OPEN) && closesAtEnd(out, NULL_OPEN.length - 1)) out = out.substring(NULL_OPEN.length, out.length - 1);
		return out;
	}

	/** Whether the `<` at `open` in `type` is closed by its last character — the `>` of a `->` arrow closes nothing. */
	private static function closesAtEnd(type: String, open: Int): Bool {
		var depth: Int = 0;
		for (i in open ... type.length) {
			final c: Int = type.fastCodeAt(i);
			if (c == '<'.code)
				depth++;
			else if (c == '>'.code && type.fastCodeAt(i - 1) != '-'.code) {
				depth--;
				if (depth == 0) return i == type.length - 1;
			}
		}
		return false;
	}

}

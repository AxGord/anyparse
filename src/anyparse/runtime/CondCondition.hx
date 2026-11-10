package anyparse.runtime;

/**
 * The one answer to "where does the condition after a conditional-compilation keyword lie", given the grammar's
 * reader of a condition's extent (`(input, at) -> end`, `at` when none: the `@:scan` reader of the grammar's
 * condition terminal). The blank between the keyword and the condition, line breaks included, is skipped here; what
 * a condition is and where it ends the grammar declares, so this class knows no language.
 */
@:nullSafety(Strict)
final class CondCondition {

	/** The condition span starting after a keyword at `from`, or null when the directive carries none. */
	public static function conditionAt(source: String, from: Int, reader: (Input, Int) -> Int): Null<Span> {
		return conditionIn(new StringInput(source), from, reader);
	}

	/** `conditionAt` over a parser's input, read in place rather than copied out. */
	public static function conditionIn(input: Input, from: Int, reader: (Input, Int) -> Int): Null<Span> {
		final start: Int = skipBlank(input, from);
		final end: Int = reader(input, start);
		return end > start ? new Span(start, end) : null;
	}

	/**
	 * Where the leading condition of a spliced fragment ends, past the blank after it: the condition is `conditionAt`'s,
	 * so the parser's splice predicates and the query side read one condition. A fragment carrying no condition (a
	 * stray `)`, an unbalanced group) answers the end of the input.
	 */
	public static function skipConditionAtom(source: String, at: Int, reader: (Input, Int) -> Int): Int {
		final input: Input = new StringInput(source);
		final atom: Null<Span> = conditionIn(input, at, reader);
		return atom == null ? source.length : skipBlank(input, atom.to);
	}

	/** The index of the first character at or after `at` that is not whitespace, line breaks included. */
	private static function skipBlank(input: Input, at: Int): Int {
		var i: Int = at;
		while (i < input.length) {
			final c: Int = input.charCodeAt(i);
			if (c != ' '.code && c != '\t'.code && c != '\n'.code && c != '\r'.code) return i;
			i++;
		}
		return i;
	}

}

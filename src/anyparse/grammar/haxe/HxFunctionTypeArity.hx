package anyparse.grammar.haxe;

using StringTools;

/**
 * Reads the parameter list of a Haxe function-type annotation out of its verbatim
 * source text — this grammar's `FunctionTypeProvider` answer.
 *
 * Text rather than tree on purpose: the `QueryNode` projection carries no parameter
 * types at all (a parameter projects as a bare `Required <name>` with no child), so
 * `TypeInfoProvider.declaredTypeSources` — the annotation verbatim — is the only
 * thing a consumer has. That makes this the legitimate case for reading source, and
 * the plugin the right home for it.
 *
 * ## Only the Haxe 4 arrow form answers
 *
 * `(A, B) -> R` is read; the curried Haxe 3 spelling `A -> B -> R` answers null.
 * The old form's arity is genuinely ambiguous — `Void -> R` meant a NULLARY function
 * for a decade and now reads as one taking `Void` — and no consumer needs it badly
 * enough to guess. A parenthesised type that is not followed by `->` (`(Int)`) is
 * not a function type and answers null as well.
 *
 * ## The scanner neutralises `->` before tracking `<>`
 *
 * Depth is tracked over `()`, `[]`, `{}` and `<>` so a comma inside `Map<Int, String>`
 * is not a parameter separator. The `>` of the `->` separator closes nothing, and a
 * function type may appear as a parameter of another (`((Int) -> Void) -> Void`), so
 * the two characters are consumed as a unit before any depth test sees them.
 */
@:nullSafety(Strict)
final class HxFunctionTypeArity {

	/**
	 * How many parameters `typeSource` takes, or null when the text is not a Haxe 4
	 * arrow function type or one of its parameters is optional, rest or defaulted.
	 */
	public static function of(typeSource: String): Null<Int> {
		final source: String = typeSource.trim();
		if (!source.startsWith('(')) return null;
		final close: Int = matchingParen(source);
		if (close < 0 || !source.substring(close + 1).trim().startsWith('->')) return null;
		final inner: String = source.substring(1, close).trim();
		if (inner == '') return 0;
		final params: Null<Array<String>> = positionalParams(inner);
		return params?.length;
	}

	private static inline function opening(c: String): Bool {
		return c == '(' || c == '[' || c == '{' || c == '<';
	}

	private static inline function closing(c: String): Bool {
		return c == ')' || c == ']' || c == '}' || c == '>';
	}

	/** The index of the `)` that closes the leading `(`, or -1 when the text never closes it. */
	private static function matchingParen(source: String): Int {
		var depth: Int = 0;
		var i: Int = 0;
		while (i < source.length) {
			if (arrowAt(source, i)) {
				i += 2;
				continue;
			}
			final c: String = source.charAt(i);
			if (opening(c))
				depth++;
			else if (c == ')') {
				depth--;
				if (depth == 0) return i;
			} else if (closing(c))
				depth--;
			i++;
		}
		return -1;
	}

	/**
	 * `inner` split on its top-level commas, or null when any parameter carries a
	 * shape a positional value cannot reproduce — see the interface's contract.
	 */
	private static function positionalParams(inner: String): Null<Array<String>> {
		final parts: Array<String> = [];
		var depth: Int = 0;
		var start: Int = 0;
		var i: Int = 0;
		while (i < inner.length) {
			if (arrowAt(inner, i)) {
				i += 2;
				continue;
			}
			final c: String = inner.charAt(i);
			if (opening(c))
				depth++;
			else if (closing(c))
				depth--;
			else if (c == ',' && depth == 0) {
				parts.push(inner.substring(start, i));
				start = i + 1;
			}
			i++;
		}
		parts.push(inner.substring(start));
		for (p in parts) if (!positional(p)) return null;
		return parts;
	}

	/** Whether a parameter spelling is positionally exact — not optional, rest or defaulted. */
	private static function positional(param: String): Bool {
		final text: String = param.trim();
		return text != '' && !text.startsWith('?') && !text.startsWith('...') && text.indexOf('=') < 0;
	}

	/** Whether the two characters at `i` spell the `->` separator, whose `>` closes nothing. */
	private static function arrowAt(text: String, i: Int): Bool {
		return text.charAt(i) == '-' && text.charAt(i + 1) == '>';
	}

}

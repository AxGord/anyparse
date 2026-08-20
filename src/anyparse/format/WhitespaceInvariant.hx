package anyparse.format;

using StringTools;

/**
 * The formatter's non-whitespace invariant: a correct formatter changes only
 * WHITESPACE, so stripping every whitespace character from the input and from
 * the writer's output must leave two identical strings.
 *
 * This is the gate the writer's own round trip cannot be: that one asks "does
 * the output re-parse to the same tree", and a writer defect is invisible to
 * it whenever the parser accepts its own broken output. The conditional-region
 * separator bug was exactly that shape — `@:forward(a, #if f b, #end, c)`
 * parses here and dies in `haxe` — so `self-status`, `fmt --list` and `lint`
 * were all green on a tree that no longer compiled. Comparing bytes instead of
 * trees is what catches it, and one pass over 846 files found four such sites.
 *
 * ## What it deliberately does NOT know
 *
 * Some formatter policies are token-level by design, and a divergence they
 * cause is CORRECT: an inserted or removed trailing comma
 * (`trailingCommaArgs`), braces added around a single statement
 * (`singleStmtBraces`), an optional `;` normalised in or out, a javadoc close
 * rewritten from `**\/` to `*\/`. This module reports the divergence and says
 * nothing about which kind it is — the caller reads it. Keeping the rule
 * "whitespace only" rather than encoding a policy list is what makes it a
 * useful diagnostic for a defect nobody has classified yet, which is the
 * situation it exists for.
 *
 * Pure and grammar-agnostic: whitespace is not a property of any one language.
 */
@:nullSafety(Strict)
final class WhitespaceInvariant {

	/** Non-whitespace characters quoted on each side of a divergence report. */
	private static inline final WINDOW: Int = 48;

	/**
	 * The first place `written` stops matching `source` once all whitespace is
	 * removed from both, or null when the invariant holds.
	 *
	 * The reported line is the SOURCE line the divergence starts on, so the
	 * caller can point at a file the user still has on disk; `expected` and
	 * `actual` quote the next run of non-whitespace characters from each side.
	 * A side that simply ran out reports an empty window, which is what a
	 * dropped or added trailing token looks like.
	 */
	public static function firstDivergence(source: String, written: String): Null<Divergence> {
		final left: Stripped = strip(source);
		final right: Stripped = strip(written);
		final leftLen: Int = left.text.length;
		final rightLen: Int = right.text.length;
		final shared: Int = leftLen < rightLen ? leftLen : rightLen;
		var i: Int = 0;
		while (i < shared && left.text.charCodeAt(i) == right.text.charCodeAt(i)) i++;
		return i == shared && leftLen == rightLen ? null : {
			line: i < left.lines.length ? left.lines[i] : lastLine(left),
			expected: left.text.substr(i, WINDOW),
			actual: right.text.substr(i, WINDOW)
		};
	}

	/** `text` with every whitespace character removed, plus the 1-based source line each kept character came from. */
	private static function strip(source: String): Stripped {
		final text: StringBuf = new StringBuf();
		final lines: Array<Int> = [];
		var line: Int = 1;
		for (i in 0...source.length) {
			final c: Int = source.fastCodeAt(i);
			if (c == '\n'.code) {
				line++;
				continue;
			}
			if (c == ' '.code || c == '\t'.code || c == '\r'.code) continue;
			text.add(source.charAt(i));
			lines.push(line);
		}
		return { text: text.toString(), lines: lines };
	}

	/** The last line the stripped source reached — the report position when the SOURCE is the side that ran out. */
	private static function lastLine(stripped: Stripped): Int {
		return stripped.lines.length == 0 ? 1 : stripped.lines[stripped.lines.length - 1];
	}

}

/** Where two whitespace-stripped strings first disagree, with a window of each side for the report. */
typedef Divergence = {
	final line: Int;
	final expected: String;
	final actual: String;
};

/** A whitespace-stripped string plus the 1-based source line of each surviving character. */
private typedef Stripped = {
	final text: String;
	final lines: Array<Int>;
};

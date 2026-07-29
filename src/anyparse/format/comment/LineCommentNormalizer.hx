package anyparse.format.comment;

import anyparse.format.WriteOptions;

/**
 * Engine-level adapter for captured C-family line comments (`//…`).
 *
 * Lives next to `BlockCommentNormalizer` so any grammar (Haxe, AS3,
 * JS, C/C++, Rust, …) wires `normalizeLineComment` into its format's
 * `defaultWriteOptions.lineCommentAdapter` and gets the standard
 * `// foo` ↔ `//foo` policy without plugin code.
 *
 * The entry point is RUN-AWARE: callers pass the whole captured
 * contiguous comment array plus the index of the entry to render, so a
 * run-wide common indent can be computed. Single-comment slots pass a
 * 1-element array.
 *
 * Two knobs drive it, read off the supplied `WriteOptions`:
 *
 * `normalizeLineCommentIndent` (default `false`) — when on, a body whose
 * first non-whitespace character is an ASCII letter or digit gets its
 * run's COMMON post-`//` whitespace prefix stripped and exactly one
 * space emitted: `'// ' + rest`. Relative indentation inside the run
 * survives, so commented-out code keeps its structure while the shared
 * over-indent goes; a lone over-indented comment collapses to one
 * space. Tabs count as whitespace. Entries that are not normalisable
 * (empty body, dividers like `//====` / `//----` / `//***`, markers
 * like `//!`, `///`-style triple slashes — the third `/` is neither
 * letter nor digit) neither contribute to nor break the run — but one
 * whose own indent opens with the run's common prefix still rides the
 * same shift, so a `}` closer or a string-continuation line stays aligned
 * with the block it belongs to. One that does not share the prefix — a
 * divider sitting flush against the slashes — falls through to the legacy
 * path below. A non-`//` entry (a block comment) DOES break the run.
 *
 * The common prefix is computed character-wise and literally, so a run
 * mixing tabs and spaces yields a short or empty prefix — the
 * conservative direction: nothing is stripped and relative indentation
 * is preserved verbatim. With an empty common prefix the pass NEVER
 * adds width: a body that already starts with whitespace falls through
 * to the legacy path and is re-emitted as authored, and only a body
 * sitting flush against the slashes picks up the single separating
 * space.
 *
 * The pass is idempotent. After one pass every body the pass rewrote
 * reads `' ' + rest`; on the next pass the run's common prefix is
 * `' ' + commonPrefix(rest-whitespace)`, and stripping it before
 * re-emitting one space reproduces the same string, so formatting twice
 * is a fixed point. A body left to the legacy path is stable for the same
 * reason: it did not move, and the members that did move only ever land
 * on that single space.
 *
 * `addLineCommentSpace` — the legacy path, mirroring haxe-formatter's
 * `MarkTokenText.printCommentLine`, used whenever the indent pass does
 * not apply:
 *  - body matches `^[/\*\-\s]+` (decoration runs like `//*****`,
 *    `//---------`, `////`, or already-spaced bodies) → keep tight,
 *    rtrim trailing whitespace
 *  - `addLineCommentSpace == true` → emit `// <trimmed body>` (insert
 *    one space after `//`)
 *  - `addLineCommentSpace == false` → emit `//<trimmed body>` (knob
 *    off: no leading-space pass)
 *
 * `run[index]` is the captured string WITH the `//` delimiter
 * (`leadingComments[i]` and the `collectTrailingFull` close-trail
 * slot store it that way). For the body-only `collectTrailing`
 * trailing form, callers pass `['//' + body]`.
 *
 * Non-`//` input (block comment, plain text, anything else) is
 * returned untouched — the helper short-circuits so callers can
 * route every captured trivia string through here without a type-
 * tag dispatch.
 */
@:nullSafety(Strict)
class LineCommentNormalizer {

	public static function normalizeLineComment(run: Array<String>, index: Int, opt: WriteOptions): String {
		final verbatim: String = run[index];
		if (!StringTools.startsWith(verbatim, '//')) return verbatim;
		final body: String = verbatim.substr(2);
		if (body.length == 0) return '//';
		if (opt.normalizeLineCommentIndent) {
			final common: String = runCommonIndent(run, index);
			// Every member whose own indent opens with the run's common prefix
			// is re-based on one space. Only ALNUM-headed bodies feed the fold,
			// but a skipped member sharing that prefix rides the same shift, so
			// a commented-out block keeps its shape instead of leaving its `}`
			// closers and continuation lines behind at the original indent.
			// An empty common prefix means there is no shared indent to strip (a
			// member sits flush against the slashes, or members disagree on
			// tab-vs-space): only a flush alnum body then picks up the
			// separating space, so the pass never GAINS a column.
			final rebase: Bool = common.length > 0 ? StringTools.startsWith(body, common) : isAlnum(StringTools.fastCodeAt(body, 0));
			if (rebase) {
				final rest: String = StringTools.rtrim(body.substr(common.length));
				return rest.length == 0 ? '//' : '// $rest';
			}
		}
		if (isDecorationPrefix(body)) return '//${StringTools.rtrim(body)}';
		final trimmed: String = StringTools.trim(body);
		return opt.addLineCommentSpace ? '// $trimmed' : '//$trimmed';
	}

	private static function isDecorationPrefix(body: String): Bool {
		if (body.length == 0) return false;
		final c: Int = StringTools.fastCodeAt(body, 0);
		return c == '/'.code || c == '*'.code || c == '-'.code || c == ' '.code || c == '\t'.code || c == '\r'.code;
	}

	/**
	 * True iff `body` (the post-`//` text) is eligible for the indent
	 * normalisation pass: its first non-whitespace character exists and is
	 * an ASCII letter or digit. Dividers, markers and `///` bodies fail here
	 * and fall through to the legacy `addLineCommentSpace` path.
	 */
	private static function isNormalizable(body: String): Bool {
		final i: Int = firstNonWhitespaceIndex(body);
		return i < body.length && isAlnum(StringTools.fastCodeAt(body, i));
	}

	/** Index of the first character of `body` that is not ` `, `\t` or `\r`; `body.length` when there is none. */
	private static function firstNonWhitespaceIndex(body: String): Int {
		var i: Int = 0;
		while (i < body.length) {
			final c: Int = StringTools.fastCodeAt(body, i);
			if (c != ' '.code && c != '\t'.code && c != '\r'.code) break;
			i++;
		}
		return i;
	}

	/** True for an ASCII letter or digit. */
	private static inline function isAlnum(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code);
	}

	/** The ` `/`\t`/`\r` prefix of `body`. */
	private static inline function leadingWhitespace(body: String): String {
		return body.substr(0, firstNonWhitespaceIndex(body));
	}

	/**
	 * Longest common post-`//` whitespace prefix over the contiguous run of
	 * `//` entries that contains `run[index]`. Expansion stops at the first
	 * non-`//` neighbour on either side; entries that fail `isNormalizable`
	 * are skipped without breaking the run. `run[index]` is always
	 * normalisable at the only call site, so the fold has at least one
	 * contributor.
	 */
	private static function runCommonIndent(run: Array<String>, index: Int): String {
		var lo: Int = index;
		while (lo > 0 && StringTools.startsWith(run[lo - 1], '//')) lo--;
		var hi: Int = index;
		while (hi < run.length - 1 && StringTools.startsWith(run[hi + 1], '//')) hi++;
		var common: Null<String> = null;
		for (k in lo ... hi + 1) {
			final b: String = run[k].substr(2);
			if (!isNormalizable(b)) continue;
			final ws: String = leadingWhitespace(b);
			common = common == null ? ws : commonPrefix(common, ws);
		}
		return common ?? '';
	}

	/** Character-wise literal longest common prefix of two strings. */
	private static function commonPrefix(a: String, b: String): String {
		final max: Int = a.length < b.length ? a.length : b.length;
		var i: Int = 0;
		while (i < max && StringTools.fastCodeAt(a, i) == StringTools.fastCodeAt(b, i)) i++;
		return a.substr(0, i);
	}

}

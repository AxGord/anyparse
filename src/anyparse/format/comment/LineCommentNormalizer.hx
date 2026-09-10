package anyparse.format.comment;

import anyparse.format.WriteOptions;

using StringTools;

/**
 * Engine-level adapter for captured C-family line comments (`//…`): a grammar wires
 * `normalizeLineComment` into its format's `defaultWriteOptions.lineCommentAdapter`
 * and gets the standard `// foo` ↔ `//foo` policy without plugin code.
 *
 * The entry point is RUN-AWARE — callers pass the whole captured contiguous comment
 * array plus the index of the entry to render, so a run-wide common indent can be
 * computed; a single-comment slot passes a 1-element array. `run[index]` carries the
 * `//` delimiter, and for the body-only trailing form callers pass `['//' + body]`.
 * Non-`//` input is returned untouched, so every captured trivia string can be
 * routed through here without a type-tag dispatch.
 *
 * `normalizeLineCommentIndent` (default `false`) strips the run's COMMON post-`//`
 * whitespace prefix from a body whose first non-whitespace character is an ASCII
 * letter or digit and emits exactly one space, so commented-out code keeps its
 * relative structure while the shared over-indent goes. An entry that is not
 * normalisable (empty body, a `//====` divider, a `//!` or `///` marker) neither
 * contributes to nor breaks the run, yet still rides the same shift when its own
 * indent opens with the common prefix — that is what keeps a `}` closer or a
 * string-continuation line aligned with the block it belongs to; one that does not
 * share the prefix falls through to the legacy path, and a non-`//` entry DOES
 * break the run.
 *
 * The common prefix is computed character-wise and literally, so a run mixing tabs
 * and spaces yields a short or empty prefix — the conservative direction, since
 * nothing is then stripped. With an empty prefix the pass NEVER adds width: only a
 * body sitting flush against the slashes picks up the separating space.
 *
 * The pass is a fixed point: every body it rewrote reads `' ' + rest`, so the next
 * run's common prefix begins with that space and stripping it before re-emitting
 * one space reproduces the same string, while a body left to the legacy path never
 * moved. That legacy path is `addLineCommentSpace` — a body matching `^[/\*\-\s]+`
 * (decoration runs, already-spaced bodies) stays tight and rtrimmed, and otherwise
 * the knob decides between `// <body>` and `//<body>`.
 */
@:nullSafety(Strict)
class LineCommentNormalizer {

	public static function normalizeLineComment(run: Array<String>, index: Int, opt: WriteOptions): String {
		final verbatim: String = run[index];
		if (!verbatim.startsWith('//')) return verbatim;
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
			final rebase: Bool = common.length > 0 ? body.startsWith(common) : isAlnum(body.fastCodeAt(0));
			if (rebase) {
				final rest: String = body.substr(common.length).rtrim();
				return rest.length == 0 ? '//' : '// $rest';
			}
		}
		if (isDecorationPrefix(body)) return '//${body.rtrim()}';
		final trimmed: String = body.trim();
		return opt.addLineCommentSpace ? '// $trimmed' : '//$trimmed';
	}

	/** True for an ASCII letter or digit. */
	private static inline function isAlnum(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code);
	}

	/** The ` `/`\t`/`\r` prefix of `body`. */
	private static inline function leadingWhitespace(body: String): String {
		return body.substr(0, firstNonWhitespaceIndex(body));
	}

	private static function isDecorationPrefix(body: String): Bool {
		if (body.length == 0) return false;
		final c: Int = body.fastCodeAt(0);
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
		return i < body.length && isAlnum(body.fastCodeAt(i));
	}

	/** Index of the first character of `body` that is not ` `, `\t` or `\r`; `body.length` when there is none. */
	private static function firstNonWhitespaceIndex(body: String): Int {
		var i: Int = 0;
		while (i < body.length) {
			final c: Int = body.fastCodeAt(i);
			if (c != ' '.code && c != '\t'.code && c != '\r'.code) break;
			i++;
		}
		return i;
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
		while (i < max && a.fastCodeAt(i) == b.fastCodeAt(i)) i++;
		return a.substr(0, i);
	}

}

package anyparse.check;

using Lambda;

/**
 * The PROSE JUDGE behind `prefer-doc-comment`'s content gates: whether one `//` comment
 * line is English documentation, as opposed to commented-out code, a tooling directive, a
 * task marker, or section decoration. Pure static string judgement — no comment-token
 * scanning, no parse tree, no anchors; those stay with the rule that owns them.
 *
 * Entry points are `declines` (directives, task markers, `readsAsProse` — gates 5-7) and
 * `carriesNoDocumentation` (empty runs and decoration — gate 9 and the content-free
 * cession); the rest are their helpers. Gate numbers in the member docs refer to
 * `PreferDocComment`'s gate list, which documents WHEN each judgement applies and what an
 * above-line run demands beyond it.
 */
@:nullSafety(Strict)
final class CommentProse {

	/** The line-comment opener, stripped from each body line. */
	public static inline final LINE_MARKER: String = '//';

	/**
	 * Tooling directives (gate 5), lower-cased and matched as a LINE PREFIX. `noqa` and
	 * `CHECKSTYLE:` are this project's own suppression markers (`Suppression`); the
	 * `@formatter:` and `#region` pairs are the two conventions foreign formatters and
	 * IDEs read out of Haxe line comments.
	 */
	private static final DIRECTIVE_MARKERS: Array<String> = ['noqa', 'checkstyle:', '@formatter:', '#region', '#endregion'];

	/** Task markers (gate 6), lower-cased and matched ANYWHERE in a line. */
	private static final TASK_MARKERS: Array<String> = ['todo', 'fixme', 'hack', 'xxx'];

	/** The characters a section rule is drawn from (gate 9) — `//----`, `// === `, `// --- Mobile touch ---`. */
	private static inline final SEPARATOR_CHARS: String = '-=*_#';

	/** The longest a DECORATED phrase can be and still read as a section label rather than a sentence (gate 9). */
	private static inline final DECORATED_LABEL_WORDS: Int = 4;

	/**
	 * Declaration and statement HEADS (gate 7): the Haxe keywords that open a line of code
	 * and never open an English sentence in lower case. Matched CASE-SENSITIVELY, which is
	 * what lets `If unset, the default applies` stay prose while `if (b) {` does not.
	 */
	private static final CODE_HEAD_KEYWORDS: Array<String> = [
		'abstract',
		'break',
		'case',
		'cast',
		'catch',
		'class',
		'continue',
		'dynamic',
		'else',
		'enum',
		'extern',
		'final',
		'function',
		'import',
		'inline',
		'interface',
		'macro',
		'new',
		'override',
		'package',
		'private',
		'public',
		'return',
		'static',
		'throw',
		'try',
		'typedef',
		'untyped',
		'using',
		'var'
	];

	/**
	 * Control-flow heads (gate 7). Unlike the declaration heads these DO open English
	 * sentences — `for internal use only`, `while loading`, `do not call this directly` —
	 * so they read as code only when the parenthesised or braced head of the construct
	 * follows.
	 */
	private static final CONTROL_HEAD_KEYWORDS: Array<String> = ['do', 'for', 'if', 'switch', 'while'];

	/**
	 * GATES 9 and the content-free cession — whether the run carries no documentation at
	 * all. Three shapes: nothing but whitespace after the `//`, and two decorations:
	 *
	 *  - a pure rule (`//----`, `// === `): nothing but `SEPARATOR_CHARS` and whitespace;
	 *  - a DECORATED LABEL (`// --- Mobile touch ---`): rule characters on both ends around a
	 *    short phrase. The decoration is what makes it a divider — the same words without it
	 *    (`// Mobile touch`) are judged by the label gates like any other run, and a sentence
	 *    long enough to be documentation is not turned into one by a leading dash.
	 */
	public static function carriesNoDocumentation(lines: Array<String>): Bool {
		if (ruleCharsOnly(lines)) return true;
		// Every line empty after the `//` — `empty-comment`'s shape, not this rule's; its
		// fix DELETES the run, where converting would emit an empty doc block.
		if (!lines.exists(line -> line != '')) return true;
		if (lines.length != 1) return false;
		final text: String = StringTools.trim(lines[0]);
		return text.length > 0 && isRuleChar(StringTools.fastCodeAt(text, 0)) && isRuleChar(StringTools.fastCodeAt(text, text.length - 1))
			&& wordCount(stripRuleChars(text)) <= DECORATED_LABEL_WORDS;
	}

	/**
	 * Gates 5-7 over one trimmed body line: a tooling directive, a task marker, or anything
	 * that does not READ AS PROSE.
	 */
	public static function declines(text: String): Bool {
		final lower: String = text.toLowerCase();
		for (marker in DIRECTIVE_MARKERS) if (StringTools.startsWith(lower, marker)) return true;
		for (marker in TASK_MARKERS) if (lower.indexOf(marker) >= 0) return true;
		return !readsAsProse(text);
	}

	/** Whether every line is drawn only from rule characters and whitespace. */
	private static function ruleCharsOnly(lines: Array<String>): Bool {
		for (line in lines) for (i in 0...line.length) {
			final c: Int = StringTools.fastCodeAt(line, i);
			if (c != ' '.code && c != '\t'.code && !isRuleChar(c)) return false;
		}
		return true;
	}

	/** Whether `c` is one of the characters a section rule is drawn from. */
	private static inline function isRuleChar(c: Int): Bool {
		return SEPARATOR_CHARS.indexOf(String.fromCharCode(c)) >= 0;
	}

	/** `text` with every rule character replaced by a space. */
	private static function stripRuleChars(text: String): String {
		final buf: StringBuf = new StringBuf();
		for (i in 0...text.length) {
			final c: Int = StringTools.fastCodeAt(text, i);
			buf.addChar(isRuleChar(c) ? ' '.code : c);
		}
		return buf.toString();
	}

	/** The number of whitespace-separated words in `text`. */
	private static function wordCount(text: String): Int {
		var words: Int = 0;
		for (part in StringTools.trim(text).split(' ')) if (StringTools.trim(part) != '') words++;
		return words;
	}

	/**
	 * Gate 7, stated POSITIVELY: whether `text` reads as prose. The rule converts what it can
	 * recognise as English, rather than dodging a list of code shapes — a blacklist of
	 * commented-out forms leaks, because every shape omitted from it converts silently and the
	 * list can only grow after the fact.
	 *
	 * Prose is a line that opens with something other than a code head and carries no
	 * punctuation English does not use:
	 *
	 *  - its first word is not a declaration / statement keyword (`CODE_HEAD_KEYWORDS`), and
	 *    not a control keyword followed by the construct's `(` or `{`
	 *    (`CONTROL_HEAD_KEYWORDS`) — the keyword sets are the LANGUAGE's, a closed fact, not a
	 *    catalogue of observed mistakes;
	 *  - it holds no `;`, `{`, `}`, `=` or `@`;
	 *  - no identifier is glued to a `(` (a CALL — prose puts a space before a bracket, as in
	 *    `… width and height (center align)`);
	 *  - no identifier is glued to a `:` that a further identifier follows (a TYPE ANNOTATION
	 *    — a prose colon is followed by a space or ends the line, and a URL's `://` is neither).
	 *
	 * QUOTED MATERIAL IS EXEMPT. Quoting is how English embeds a foreign shape — an example
	 * value, a fragment of code — so a balanced `"…"` or backtick span is judged as the
	 * QUOTATION it is, rather than as punctuation of the line: `// the model, -- "Core(TM)2
	 * @ 2.80GHz"` describes a field whatever the sample inside the quotes looks like. Every
	 * check above therefore takes its CHARACTERS from the text with those spans blanked
	 * (`maskQuotedSpans`), so nothing inside a quotation can be the line's own punctuation.
	 *
	 * The judgement is SPLIT, though. Whether a `;` / `{` / `}` sits in a STRUCTURAL position
	 * is a question about what surrounds it, and blanking a span changes exactly that: it
	 * would leave `// stop; "really"` reading as `;`-terminated and `// "note" } tail` as a
	 * line-opening `}`, both prose at HEAD. So those positions are asked of the RAW line —
	 * which loses nothing, because a `;` inside a balanced span can never terminate the line
	 * anyway: its own closing delimiter follows it.
	 *
	 * An empty line is prose: it is the paragraph break of a multi-line run.
	 */
	private static function readsAsProse(text: String): Bool {
		final bare: String = maskQuotedSpans(text);
		final head: String = firstWord(bare);
		return !CODE_HEAD_KEYWORDS.contains(head) && !(CONTROL_HEAD_KEYWORDS.contains(head) && opensBracket(bare.substr(head.length)))
			&& !hasCodePunctuation(bare, text);
	}

	/**
	 * `text` with every BALANCED `"…"` span and every BALANCED backtick span blanked to
	 * spaces, delimiters included — what `readsAsProse` judges instead of the raw line.
	 *
	 * LENGTH-PRESERVING, and load-bearing that it is: `hasCodePunctuation` walks the masked
	 * text but reads the RAW line on either side of a `;` / `{` / `}`, using the offset the
	 * masked walk gave it. One character of drift would look at the wrong side.
	 *
	 * An opener with NO closer masks NOTHING — where the span ends is unknowable, and
	 * keeping the text costs at most a declined conversion (`// set "flag = 1` keeps its `=`
	 * and is refused). The scan is left-to-right and non-nesting: the first closer wins.
	 *
	 * SINGLE QUOTES ARE NOT MASKED. An apostrophe is prose's own character (`don't`, `the
	 * user's name`), so pairing on it would blank the text BETWEEN two apostrophes and hide
	 * real code punctuation inside ordinary English.
	 */
	private static function maskQuotedSpans(text: String): String {
		final buf: StringBuf = new StringBuf();
		var i: Int = 0;
		while (i < text.length) {
			final c: Int = StringTools.fastCodeAt(text, i);
			final closeAt: Int = c == '"'.code || c == '`'.code ? text.indexOf(String.fromCharCode(c), i + 1) : -1;
			if (closeAt < 0) {
				buf.addChar(c);
				i++;
			} else {
				buf.add(StringTools.rpad('', ' ', closeAt + 1 - i));
				i = closeAt + 1;
			}
		}
		return buf.toString();
	}

	/** `text`'s leading run of identifier characters. */
	private static function firstWord(text: String): String {
		var i: Int = 0;
		while (i < text.length && isIdentChar(StringTools.fastCodeAt(text, i))) i++;
		return text.substr(0, i);
	}

	/** Whether `rest`, past any spaces, opens a `(` or `{` — the head of a control construct. */
	private static function opensBracket(rest: String): Bool {
		var i: Int = 0;
		while (i < rest.length && StringTools.fastCodeAt(rest, i) == ' '.code) i++;
		if (i >= rest.length) return false;
		final c: Int = StringTools.fastCodeAt(rest, i);
		return c == '('.code || c == '{'.code;
	}

	/**
	 * Whether the comment line carries punctuation in a position English does not use but
	 * Haxe does. TWO VIEWS of the same line, indexed alike because `maskQuotedSpans` is
	 * length-preserving: `bare` has every balanced quoted span blanked and supplies the
	 * CHARACTERS, `raw` is the line as written and serves the STRUCTURAL far-side reads of
	 * the `;` / `{` / `}` arms. The `(` and `:` arms read their neighbours on `bare` too —
	 * a blanked quote judges like the space it became.
	 *
	 * `=` and `@` are unconditional — neither has an English role. The rest are judged by
	 * POSITION, because the characters themselves are ordinary prose:
	 *
	 *  - `;` reads as a STATEMENT TERMINATOR only when nothing but a trailing `//` comment
	 *    follows it on the RAW line. A prose semicolon joins two clauses and has more
	 *    sentence behind it (`… return filenames in NFD; servers and Windows use NFC.`) —
	 *    and a quotation is such a continuation, so `// stop; "really"` stays prose.
	 *  - `{` reads as a BLOCK OPENER only at the RAW line's end, `}` as a closer only at its
	 *    start or end. Braces inside a sentence are describing a value
	 *    (`Returns {x, y} in stage space.`).
	 *  - `(` is a CALL only when glued to an identifier; prose puts a space before a bracket
	 *    (`… width and height (center align)`).
	 *  - `:` is a TYPE ANNOTATION only between two identifiers; a prose colon is followed by
	 *    a space or ends the line, and a URL's `://` is neither.
	 */
	private static function hasCodePunctuation(bare: String, raw: String): Bool {
		for (i in 0...bare.length) {
			final c: Int = StringTools.fastCodeAt(bare, i);
			if (c == '='.code || c == '@'.code) return true;
			if (c == ';'.code && terminatesLine(raw, i + 1)) return true;
			if (c == '{'.code && terminatesLine(raw, i + 1)) return true;
			if (c == '}'.code && (terminatesLine(raw, i + 1) || StringTools.trim(raw.substring(0, i)) == '')) return true;
			if (c == '('.code && i > 0 && isIdentChar(StringTools.fastCodeAt(bare, i - 1))) return true;
			if (
				c == ':'.code && i > 0 && i + 1 < bare.length && isIdentChar(StringTools.fastCodeAt(bare, i - 1))
				&& isIdentStart(StringTools.fastCodeAt(bare, i + 1))
			)
				return true;
		}
		return false;
	}

	/** Whether nothing but whitespace, or a trailing `//` comment, follows `from` — the line-terminator position. */
	private static function terminatesLine(text: String, from: Int): Bool {
		final rest: String = StringTools.trim(text.substr(from));
		return rest.length == 0 || StringTools.startsWith(rest, LINE_MARKER);
	}

	/** Whether `c` may appear inside a Haxe identifier. */
	private static inline function isIdentChar(c: Int): Bool {
		return isIdentStart(c) || (c >= '0'.code && c <= '9'.code);
	}

	/** Whether `c` may START a Haxe identifier. */
	private static inline function isIdentStart(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || c == '_'.code || c == '$'.code;
	}

}

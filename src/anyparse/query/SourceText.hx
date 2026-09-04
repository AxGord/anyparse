package anyparse.query;

using StringTools;
using Lambda;

import anyparse.runtime.Span;

/**
 * Character-, word- and line-level primitives over RAW source text. Nothing here reads the
 * projected tree, asks the grammar plugin anything, or knows what language it is looking at:
 * every member takes a string (plus offsets) and answers a question the scanner underneath
 * every span computation needs — is this byte an identifier character, where does this line
 * start, where is the first word-boundary occurrence of this name inside this window.
 *
 * Lifted out of `RefactorSupport` as one responsibility: it is what the two highest-fan-in
 * members of that type (`isSpace`, `isIdentChar`) belong to, and it is the layer every other
 * extracted module sits on. Keeping it separate is what makes those modules readable — a body
 * that scans text calls this by name rather than reaching into a grab-bag.
 */
@:nullSafety(Strict)
final class SourceText {

	/**
	 * How many characters of the offending source a refusal diagnostic quotes back — an unparsed
	 * conditional-compilation region, or the declaration line a doc comment was about to lose —
	 * enough to recognise it in the file, short enough to keep the message one line.
	 */
	public static inline final REGION_EXCERPT_CHARS: Int = 60;

	/**
	 * The last dotted segment of `dotted` — the simple name a plain import binds
	 * (`pkg.sub.Foo` -> `Foo`), and the whole string when it carries no dot at all.
	 *
	 * Purely textual: it splits on the LAST `.` and asks nothing of the tree, so it
	 * is equally correct for an import payload, a canonical type path, a `using`
	 * target and a dotted field path. Callers that need the module-vs-sub-type
	 * distinction (`pkg.Mod.Sub`) must resolve that themselves — this returns `Sub`.
	 */
	public static inline function lastSegment(dotted: String): String {
		final dot: Int = dotted.lastIndexOf('.');
		return dot < 0 ? dotted : dotted.substring(dot + 1);
	}

	/** A name is renameable when it is a valid identifier and not `this`. */
	public static inline function isRenameableName(name: Null<String>): Bool {
		return name != null && name != 'this' && isIdentifier(name);
	}

	public static inline function isIdentStartChar(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || c == '_'.code;
	}

	/** Does `s` begin with an upper-case ASCII letter — the Haxe convention a type name follows, distinguishing a type reference from a lower-case value / package segment? */
	public static inline function isUpperInitial(s: String): Bool {
		final c: Int = s.fastCodeAt(0);
		return c >= 'A'.code && c <= 'Z'.code;
	}

	public static inline function isIdentChar(c: Int): Bool {
		return isIdentStartChar(c) || (c >= '0'.code && c <= '9'.code);
	}

	/** Is `c` an ASCII space / tab / newline / carriage return? */
	public static inline function isSpace(c: Int): Bool {
		return c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
	}

	/** Whether `code` is whitespace that does NOT end a line — space, tab, carriage return. */
	public static inline function isHorizontalSpace(code: Int): Bool {
		return code == ' '.code || code == '\t'.code || code == '\r'.code;
	}

	/**
	 * Offset of the first word-boundary occurrence of `name` within
	 * `[span.from, span.to)`, or -1 when not found. A word boundary
	 * requires the characters immediately before and after the match to
	 * be non-identifier characters (or the span edge), so renaming `x`
	 * inside `var x = xs[0]` matches the binding `x`, not the `x` inside
	 * `xs`.
	 */
	public static function identTokenOffset(source: String, span: Span, name: String): Int {
		final from: Int = span.from < 0 ? 0 : span.from;
		final to: Int = span.to <= source.length ? span.to : source.length;
		var i: Int = from;
		while (i + name.length <= to) {
			final at: Int = source.indexOf(name, i);
			if (at < 0 || at + name.length > to) return -1;
			final beforeOk: Bool = at == 0 || !isIdentChar(source.fastCodeAt(at - 1));
			final afterIdx: Int = at + name.length;
			final afterOk: Bool = afterIdx >= source.length || !isIdentChar(source.fastCodeAt(afterIdx));
			if (beforeOk && afterOk) return at;
			i = at + 1;
		}
		return -1;
	}

	/** Whole-string check: a non-empty identifier (`[A-Za-z_][A-Za-z0-9_]*`). */
	public static function isIdentifier(s: String): Bool {
		if (s.length == 0) return false;
		final first: Int = s.fastCodeAt(0);
		if (!isIdentStartChar(first)) return false;
		for (i in 1...s.length) if (!isIdentChar(s.fastCodeAt(i))) return false;
		return true;
	}

	/**
	 * The offset just past the whitespace run starting at `from`, bounded by `stop`.
	 * Whitespace ONLY — a comment stops the scan, which is what a caller reading tokens
	 * out of source text wants: `skipForwardTrivia` swallows comments and so hides them
	 * from a comment guard. The canonical home for the hand-scan of a declaration head;
	 * `redundant-property-access` is its first caller, and the private copies still in
	 * `trivial-getter` / `redundant-map-iter-key` / `map-keys-lookup` belong here too.
	 */
	public static function skipSpaces(source: String, from: Int, stop: Int): Int {
		var i: Int = from;
		while (i < stop && isSpace(source.fastCodeAt(i))) i++;
		return i;
	}

	/**
	 * Parse a non-negative decimal integer, returning null when the string
	 * has any non-digit character — so a coordinate like `3:1x` or a
	 * permutation index `2x` is rejected rather than silently resolving to
	 * the leading digits. Shared by the CLI coordinate parser and the
	 * change-signature permutation parser.
	 */
	public static function parseStrictInt(s: String): Null<Int> {
		if (s.length == 0) return null;
		for (j in 0...s.length) {
			final c: Int = s.fastCodeAt(j);
			if (c < '0'.code || c > '9'.code) return null;
		}
		return Std.parseInt(s);
	}

	/**
	 * The whitespace prefix of the line `from` sits on, or `''` when anything else precedes that
	 * offset on the line. A multi-statement splice re-indents its continuation lines with this, so
	 * the rewritten region still reads as source for the round trip that parses it back; the writer
	 * re-indents the whole file afterwards regardless.
	 */
	public static function lineIndentAt(source: String, from: Int): String {
		final prefix: String = source.substring(source.lastIndexOf('\n', from) + 1, from);
		return prefix.trim() == '' ? prefix : '';
	}

	/**
	 * Is the source spanned by `span` — with its first and last byte stripped
	 * (a brace-delimited block's `{` / `}`) — whitespace-only? A block holding
	 * only a comment is non-blank: a comment carries no statement, but it is
	 * source a fix must not silently discard (it may be the only trace of
	 * intent behind an otherwise-empty block). Shared by `empty-block` (an
	 * empty `{}` control-flow body) and `constant-condition` (a dead branch a
	 * fix would eliminate).
	 */
	public static function isBlankSpan(span: Span, source: String): Bool {
		final inner: String = source.substring(span.from + 1, span.to - 1);
		return inner.trim() == '';
	}

	/** The offset of the start of the line `at` sits on. */
	public static function startOfLine(source: String, at: Int): Int {
		var from: Int = at;
		while (from > 0 && source.fastCodeAt(from - 1) != '\n'.code) from--;
		return from;
	}

	/**
	 * The offset just past the first token at `from` — the run of identifier characters
	 * when `from` is on one (a name / keyword), else the single delimiter / operator
	 * character. Lets a cursor land anywhere within a node's opening token and still
	 * resolve the node, matching the forgiving `ast --at` rather than an exact `span.from`.
	 */
	public static function firstTokenEnd(source: String, from: Int): Int {
		if (from < 0 || from >= source.length) return from;
		if (!isIdentChar(source.fastCodeAt(from))) return from + 1;
		var i: Int = from + 1;
		while (i < source.length && isIdentChar(source.fastCodeAt(i))) i++;
		return i;
	}

	/**
	 * Whether `text` contains a comma outside any `()`/`[]`/`{}` nesting and outside a
	 * string literal — the multi-declaration separator of `var i, j = n`. `<>` is
	 * deliberately not tracked (a generic type-parameter comma reads as top-level,
	 * which consumers treat conservatively).
	 * Whether `decl` is a MULTI-declarator list (`var a = 1, b = 2` / `var a, b`) rather than a
	 * single binding — every binding after the first projects as a continuation node, so the
	 * question the grammar already answers is asked of the TREE. `continuationKinds` is the
	 * plugin's `localDeclContinuationKinds` (Haxe: `VarMore`). Supersedes scanning the
	 * declaration's source text for a separator comma: no character-level scan can tell
	 * `var a = 1, b = 2` from the comma inside a `Map<K, V>` annotation, and reading the latter
	 * as a separator makes a rewrite refuse a shape it handles perfectly.
	 */
	public static function isMultiDeclarator(decl: QueryNode, continuationKinds: Array<String>): Bool {
		return decl.children.exists(child -> continuationKinds.contains(child.kind));
	}

	/**
	 * Whether only spaces and tabs separate `at` from the start of its line — the test that tells a declaration's own leading comment from the PREVIOUS declaration's trailing
	 * one. Both end just above the next declaration and are equally adjacent to it; only
	 * the line the comment opens on says whose it is.
	 */
	public static function startsItsLine(source: String, at: Int): Bool {
		var i: Int = at - 1;
		while (i >= 0 && (source.fastCodeAt(i) == ' '.code || source.fastCodeAt(i) == '\t'.code)) i--;
		return i < 0 || source.fastCodeAt(i) == '\n'.code;
	}

	/**
	 * `name` respelled UPPER_SNAKE: leading and internal underscores separate segments, and so does
	 * every capital that OPENS a word — one preceded by a lower-case letter or a digit (`cellsNum` ->
	 * `CELLS_NUM`), or one closing an acronym run before a new word (`urlPath` -> `URL_PATH`). An
	 * already-UPPER_SNAKE name survives unchanged.
	 *
	 * Shared rather than per-consumer: `field-init-in-constructor` derives a hoisted constant's name
	 * from a field's, and the `naming` autofix derives a constant's SECOND conforming spelling from
	 * its first — one question, and two copies of this answer would drift on the next acronym case.
	 */
	public static function upperSnake(name: String): String {
		final segments: Array<String> = [];
		var current: StringBuf = new StringBuf();
		for (i in 0...name.length) {
			final code: Int = name.fastCodeAt(i);
			if (code == '_'.code || (isUpperCode(code) && current.length > 0 && opensWord(name, i))) {
				if (current.length > 0) segments.push(current.toString());
				current = new StringBuf();
			}
			if (code != '_'.code) current.addChar(code);
		}
		if (current.length > 0) segments.push(current.toString());
		return segments.join('_').toUpperCase();
	}

	/**
	 * A single-line excerpt of `span`'s source text for a diagnostic — whitespace runs collapsed
	 * to one space and the result capped at `REGION_EXCERPT_CHARS`, so a region spanning several
	 * source lines still names itself in one message line.
	 */
	public static function regionExcerpt(source: String, span: Span): String {
		final flat: String = ~/\s+/g.replace(source.substring(span.from, span.to), ' ').trim();
		return flat.length <= REGION_EXCERPT_CHARS ? flat : '${flat.substr(0, REGION_EXCERPT_CHARS)}...';
	}

	/**
	 * Whether `source` spells `name` as a standalone identifier token anywhere inside `span`.
	 *
	 * A `#`-prefixed spelling is skipped: `#end` / `#if` / `#else` are the directive keywords that
	 * DELIMIT the region, not references inside it, and every such region ends in one — counting
	 * them would refuse every rename of a binding called `end` in any file carrying a splice.
	 */
	public static function mentionsIdent(source: String, span: Span, name: String): Bool {
		var at: Int = source.indexOf(name, span.from);
		while (at >= 0 && at + name.length <= span.to) {
			if (standaloneIdentAt(source, name, at) && (at == 0 || source.fastCodeAt(at - 1) != '#'.code)) return true;
			at = source.indexOf(name, at + 1);
		}
		return false;
	}

	/** The index of the LAST occurrence of `name` in `head` that stands alone as an identifier, or -1. */
	public static function lastStandaloneIdentIndex(head: String, name: String): Int {
		var at: Int = head.lastIndexOf(name);
		while (at >= 0) {
			if (standaloneIdentAt(head, name, at)) return at;
			if (at == 0) return -1;
			at = head.lastIndexOf(name, at - 1);
		}
		return -1;
	}

	/** The index of the FIRST occurrence of `name` in `head` that stands alone as an identifier, or -1. */
	public static function firstStandaloneIdentIndex(head: String, name: String): Int {
		var at: Int = head.indexOf(name);
		while (at >= 0) {
			if (standaloneIdentAt(head, name, at)) return at;
			at = head.indexOf(name, at + 1);
		}
		return -1;
	}

	/** Index of the first character of the line containing `i` (just past the preceding newline). */
	public static function lineStartOf(source: String, i: Int): Int {
		final nl: Int = source.lastIndexOf('\n', i);
		return nl < 0 ? 0 : nl + 1;
	}

	/** Whether the occurrence of `name` at `at` in `head` stands alone — no identifier character on either side. */
	private static inline function standaloneIdentAt(head: String, name: String, at: Int): Bool {
		final after: Int = at + name.length;
		return (at == 0 || !isIdentChar(head.fastCodeAt(at - 1))) && (after >= head.length || !isIdentChar(head.fastCodeAt(after)));
	}

	private static inline function isUpperCode(code: Int): Bool {
		return code >= 'A'.code && code <= 'Z'.code;
	}

	/** True when the capital at `at` OPENS a word: it follows a non-capital, or it closes an acronym run before a new word. */
	private static function opensWord(name: String, at: Int): Bool {
		if (!isUpperCode(name.fastCodeAt(at - 1))) return true;
		final next: Int = at + 1 < name.length ? name.fastCodeAt(at + 1) : 0;
		return next >= 'a'.code && next <= 'z'.code;
	}

}

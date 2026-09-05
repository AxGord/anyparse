package anyparse.query;

using StringTools;
using Lambda;

import anyparse.query.LexicalRegions.LexRegion;
import anyparse.runtime.Span;

/**
 * The COMMENT token model of one source: which lexical regions are comments, where a comment
 * begins and ends, what its body is once the delimiters and the gutter come off, whether a
 * block is a documentation block, and what prefix a new line spliced into it must carry.
 *
 * One responsibility, read in both directions. The READ half answers "what is written here"
 * for the checks that must not silently drop a comment and for the ops that address one; the
 * WRITE half (`docComment`, `reflowIntoComment`, `openGrownDocBlock`, `commentContinuation`)
 * answers "what bytes keep this block well-formed when text goes into it". They are one module
 * because they share the gutter and continuation model — a splice that does not agree with the
 * reader about where a comment's body starts corrupts the block.
 *
 * Everything takes the ALREADY-SCANNED regions (`GrammarPlugin.lexicalRegions`) or plain source
 * plus offsets; nothing rescans, so a caller that asks the plugin once per file pays once.
 */
@:nullSafety(Strict)
final class SourceComments {

	/**
	 * The doc-comment opener — what distinguishes documentation from a plain `/* … *\/` banner.
	 */
	private static final DOC_OPEN: String = '/**';

	/**
	 * Whether `text` holds a `//` or `/*` comment marker. The primitive under
	 * `hasCommentMarker` and under `CheckScan.hasCommentMarker`, exposed separately for the
	 * callers whose subject is not a contiguous source range — a concatenation of trivia
	 * gaps, or one already-trimmed line.
	 *
	 * Deliberately STRING-BLIND: a marker inside a string literal (`'http://x'`) answers yes.
	 * See `hasCommentMarker` for why that stays.
	 */
	public static inline function textHasCommentMarker(text: String): Bool {
		return text.indexOf('//') >= 0 || text.indexOf('/*') >= 0;
	}

	/**
	 * Whether `[from, to)` of `source` holds a `//` or `/*` comment marker — the "don't
	 * delete a comment" guard every rewriting check consults before regenerating a region.
	 * An empty or reversed range answers no; the guard is load-bearing, since
	 * `String.substring` SWAPS a reversed pair and would otherwise scan the wrong text.
	 *
	 * ## Why it stays string-blind
	 *
	 * The scan cannot tell a real marker from one inside a string literal, so `'http://x'`
	 * reads as a comment. Teaching it about literals would make it answer `false` on inputs
	 * where it now answers `true` — a TIGHTENING, and a shared predicate may only be
	 * tightened when every caller's conservative direction points the same way.
	 *
	 * It does not. For nearly every consumer a spurious `true` REFUSES a rewrite (report-only
	 * instead of autofixed) — harmless, and the direction that never deletes a comment. The
	 * exceptions are `CheckScan`'s negation machinery — `negateConditionText`,
	 * `negationIsClean` and the `eqFlipText` it dispatches through — where the answer is not
	 * a refusal but a TIER SELECTOR: a `true` routes the rewrite to the verbatim text
	 * fallback, and `negationIsClean` then reports the site as clean precisely BECAUSE that
	 * tier declines nothing. Making the scan literal-aware moves such a condition onto the
	 * De Morgan tier, which can decline — flipping a finding off — and changes the text
	 * `eqFlipText` emits. That is a real behaviour change, not extra safety, so the
	 * string-blind answer is the shared contract and any caller that needs precision must
	 * ask the lexical regions (`scanLexicalRegions`) rather than tighten this.
	 */
	public static inline function hasCommentMarker(source: String, from: Int, to: Int): Bool {
		return from < to && textHasCommentMarker(source.substring(from, to));
	}

	/** Whether the block comment opening at `open` is a `/**` doc rather than a plain block. */
	public static inline function isDocOpener(source: String, open: Int): Bool {
		return open + 2 < source.length && source.fastCodeAt(open + 2) == '*'.code;
	}

	/**
	 * Wrap `text` as a doc-comment block, one ` * ` line per input line. Its own doc had been orphaned onto `NewFile.parseSections`, one file over.
	 */
	public static function docComment(text: String): String {
		final lines: Array<String> = trimBlankEdges(text.split('\n'));
		final buf: StringBuf = new StringBuf();
		buf.add('/**\n');
		for (line in lines) {
			final body: String = ungutter(line);
			buf.add(body == '' ? ' *\n' : ' * $body\n');
		}
		buf.add(' */');
		return buf.toString();
	}

	/**
	 * The span of the comment at `cursor`, or null if the cursor is not on a
	 * comment. A block comment is returned whole; a full-line line comment is
	 * merged with the contiguous run of full-line line comments directly above
	 * and below it (no blank line, no code between), so a line-comment block is
	 * addressed as one unit; a trailing line comment after code is returned
	 * alone. String literals are skipped, so an opener inside a string is not
	 * mistaken for a comment.
	 */
	public static function commentBlockAt(source: String, cursor: Int, regions: Array<LexRegion>): Null<Span> {
		final toks: Array<{ from: Int, to: Int, isLine: Bool }> = collectCommentTokens(regions);
		var hitIdx: Int = -1;
		for (k in 0...toks.length) if (cursor >= toks[k].from && cursor < toks[k].to) {
			hitIdx = k;
			break;
		}
		if (hitIdx < 0) return null;
		final hit: { from: Int, to: Int, isLine: Bool } = toks[hitIdx];
		if (!hit.isLine || !isFullLineComment(source, hit.from)) return new Span(hit.from, hit.to);
		var lo: Int = hitIdx;
		while (lo > 0 && contiguousLineComments(source, toks[lo - 1], toks[lo])) lo--;
		var hi: Int = hitIdx;
		while (hi < toks.length - 1 && contiguousLineComments(source, toks[hi], toks[hi + 1])) hi++;
		return new Span(toks[lo].from, toks[hi].to);
	}

	/**
	 * The comment tokens among `regions` — the line and block comments of one source, in source
	 * order, each as `{ from, to, isLine }`.
	 *
	 * Takes the SCANNED regions rather than the source: the scan is a property of the grammar
	 * (`GrammarPlugin.lexicalRegions`), and a caller that asks the plugin once per file can hand
	 * the same array to every consumer instead of re-lexing per call.
	 */
	public static function collectCommentTokens(regions: Array<LexRegion>): Array<{ from: Int, to: Int, isLine: Bool }> {
		final out: Array<{ from: Int, to: Int, isLine: Bool }> = [];
		for (region in regions) switch region.kind {
			case LineComment:
				out.push({ from: region.from, to: region.to, isLine: true });
			case BlockComment:
				out.push({ from: region.from, to: region.to, isLine: false });
			case StringLit, RegexLit:
		}
		return out;
	}

	/**
	 * Every NON-CODE region of `source` — comment, string literal or regex literal — as `[from, to)`
	 * spans in source order. The sibling of `collectCommentTokens` over the same single lexer, for a
	 * caller that only needs to answer "is this offset real code?" (the conditional-compilation
	 * directive reader) and must not grow a lexer of its own. Not memoised: each call re-lexes.
	 */
	public static function collectNonCodeRegions(regions: Array<LexRegion>): Array<Span> {
		return [for (region in regions) new Span(region.from, region.to)];
	}

	/**
	 * Every COMMENT region of `source` as `[from, to)` spans in source order — the strictly
	 * narrower sibling of `collectNonCodeRegions`, for a caller masking text that cannot possibly
	 * bind or reference a name.
	 *
	 * STRING literals are deliberately NOT included, and the distinction is load-bearing rather
	 * than cosmetic: a single-quoted Haxe string INTERPOLATES, so `'${Foo.x}'` is a genuine
	 * reference to `Foo`, and masking the literal WHOLE would let a name-freeness scan conclude
	 * the name is unbound when it is read right there. A comment carries no such risk. A caller
	 * that wants the inert TEXT of a literal masked too cannot get it from a lexer at all — which
	 * bytes of a literal are text is a question only the parse answers, and `InertRegions` answers
	 * it off the tree. Not memoised: each call re-lexes, so a per-file caller should hoist it.
	 */
	public static function collectCommentRegions(regions: Array<LexRegion>): Array<Span> {
		return [for (token in collectCommentTokens(regions)) new Span(token.from, token.to)];
	}

	/**
	 * Whether `tok` is a DOC block — opened with the doc marker and carrying a
	 * non-blank body. A line comment, a plain `/* … *\/` banner (a license header, a
	 * section label) and the empty `/**` `*\/` form are all NOT docs, which is the
	 * discrimination `docExtendedSpan` makes and every doc-aware check needs.
	 */
	public static function isDocBlock(source: String, tok: { from: Int, to: Int, isLine: Bool }): Bool {
		return !tok.isLine && source.substring(tok.from, tok.from + DOC_OPEN.length) == DOC_OPEN && !blockCommentIsBlank(source, tok);
	}

	/**
	 * Whether a CLOSED block comment's interior holds no content — only whitespace and the
	 * `*` gutter characters a doc lays its lines out with, so `/**` `*\/`, `/***\/` and a
	 * marker-only multi-line block all qualify. An unclosed block is never blank: its
	 * interior is whatever runs to end of file.
	 */
	public static function blockCommentIsBlank(source: String, tok: { from: Int, to: Int, isLine: Bool }): Bool {
		if (tok.isLine) return false;
		final closed: Bool = tok.from + 2 <= tok.to - 2 && source.fastCodeAt(tok.to - 2) == '*'.code // noqa: magic-number
			&& source.fastCodeAt(tok.to - 1) == '/'.code;
		if (!closed) return false;
		for (i in tok.from + 2...tok.to - 2) { // noqa: magic-number
			final c: Int = source.fastCodeAt(i);
			if (!SourceText.isSpace(c) && c != '*'.code) return false;
		}
		return true;
	}

	/**
	 * Body span of a comment token — the text between the opener (`//` or the
	 * block opener) and the closer, with a closed block's trailing delimiter
	 * excluded and a line comment running to the newline. Shared by the comment
	 * finder (`Cli.appendCommentHits`) and the comment rewriter (`CommentRewrite`).
	 */
	public static function commentBody(source: String, tok: { from: Int, to: Int, isLine: Bool }): Span {
		final closed: Bool = !tok.isLine && tok.to >= tok.from + 4 && StringTools.fastCodeAt(source, tok.to - 2) == '*'.code // noqa
			&& source.fastCodeAt(tok.to - 1) == '/'.code;
		final bodyEnd: Int = closed ? tok.to - 2 : tok.to;
		return new Span(tok.from + 2, bodyEnd);
	}

	/**
	 * The text every NEW line of a splice into the comment token `tok` must begin with, so
	 * the block keeps the continuation prefix it already has. It is read off the block's own
	 * FIRST interior line — `// ` at the line comment's indent, everything up to and including
	 * a star-guttered line's star plus one space, and for a block with no gutter (the
	 * `/**` … `**\/` spelling, commented-out code, a free-form paragraph) that line's own
	 * indentation.
	 *
	 * Reading it off the OPENER instead is what this function did until S39, and a gutter-less
	 * block indents its interior one level DEEPER than its delimiters — so every line a splice
	 * added landed one level short of the text it joined, and flush LEFT when the block sat at
	 * column 0. Both spellings of the closer are skipped on the way, so a block with no interior
	 * at all still falls through to the one-line case below rather than reading `*\/` as a gutter.
	 *
	 * The ops that splice into a comment splice RAW, and the writer re-emits a comment
	 * interior byte for byte, so a replacement carrying a real newline started a line with no
	 * gutter at all. The writer then re-bases the whole run onto the shallowest line, which is
	 * why ONE unguttered line pushed every guttered sibling one level deeper — and `fmt --list`
	 * called the result canonical, because it IS what the writer emits. This is what the
	 * splicers prefix with instead.
	 */
	public static function commentContinuation(source: String, tok: { from: Int, to: Int, isLine: Bool }): String {
		var lineStart: Int = tok.from;
		while (lineStart > 0 && source.fastCodeAt(lineStart - 1) != '\n'.code) lineStart--;
		var indent: String = source.substring(lineStart, tok.from);
		if (indent.trim() != '') indent = indent.substring(0, indent.length - indent.ltrim().length);
		if (tok.isLine) return '$indent// ';
		final body: String = source.substring(tok.from + 2, tok.to);
		for (line in body.split('\n').slice(1)) {
			final text: String = line.trim();
			if (text == '' || text == '*/' || text == '**/') continue;
			return interiorContinuation(line);
		}
		// No interior line to read: a one-line `/** … */` whose replacement is about to become
		// several. A doc opener means a guttered block; a plain one means none.
		return tok.from + 2 < source.length && source.fastCodeAt(tok.from + 2) == '*'.code ? '$indent * ' : indent;
	}

	/**
	 * A one-line `/** … *\/` whose body has just grown past one line, re-opened: the doc's text
	 * moves off the opener onto its own continuation line and the closer gets one of its own.
	 *
	 * Leaving the closer on the last content line is writer-UNSTABLE. The writer re-bases a block
	 * comment's continuation run, and a lone `\t * text *\/` line's common prefix is `\t ` rather
	 * than `\t`, so the space before the star is eaten and the result reads `\t* text *\/`,
	 * misaligned under the opener — canonical, and reported by nothing.
	 *
	 * `body` is the comment's interior INCLUDING the `/**`'s second star; `continuation` is what
	 * every line after the first already carries.
	 */
	public static function openGrownDocBlock(body: String, continuation: String): String {
		final nl: Int = body.indexOf('\n');
		// `''.indexOf('\n')` is -1, so the empty body is already covered by `nl < 0`.
		if (nl < 0 || body.fastCodeAt(0) != '*'.code || !continuation.endsWith('* ')) return body;
		final first: String = body.substring(1, nl).ltrim();
		// A replacement whose FIRST line is empty must leave the bare gutter, not a gutter and a
		// trailing space — `reflowIntoComment` rtrims for the same reason, and the writer re-emits a
		// comment interior verbatim, so `fmt --list` calls trailing whitespace in one canonical.
		final head: String = first == '' ? continuation.rtrim() : continuation + first;
		final tail: String = body.substring(nl).rtrim();
		// The closer aligns under the gutter's star, so it sits at the continuation minus its `* ` —
		// which is why a continuation that does not END in one is handed back untouched above rather
		// than losing two characters of its own indentation.
		final closer: String = continuation.substring(0, continuation.length - 2);
		return '*\n$head$tail\n$closer';
	}

	/**
	 * `text` prepared for splicing into a comment whose continuation prefix is `continuation`:
	 * the first line lands wherever the match did and is left alone, and every following line
	 * gets the prefix — its own caller-written gutter stripped first, so a payload that already
	 * carries one is not doubled. A line that would hold nothing but the prefix is rtrimmed, so
	 * a paragraph break does not become trailing whitespace.
	 */
	public static function reflowIntoComment(text: String, continuation: String): String {
		final lines: Array<String> = text.split('\n');
		if (lines.length < 2) return text;
		// Line 0 lands wherever the match did, so it keeps its position — but it is exactly as liable
		// to carry a caller-written gutter as any other, and leaving it raw produced ` *  * text` that
		// no gate in this project can see. Ungutter it too, splice it where it was.
		final out: Array<String> = [ungutter(lines[0])];
		for (i in 1...lines.length) {
			final body: String = ungutter(lines[i]);
			out.push(body.trim() == '' ? continuation.rtrim() : continuation + body);
		}
		return out.join('\n');
	}

	/**
	 * Normalize a comment BODY for cross-line literal matching: fold each line
	 * continuation — a `\n` or `\r\n`, the following whitespace, blank lines, and
	 * one ` * ` doc-marker per line — into a single space, so a phrase wrapped
	 * across two ` * ` lines reads as one run. Returns the normalized text plus a
	 * `map` from each normalized index to the original body offset it came from,
	 * with `map[text.length] == body.length`, so a match found in the normalized
	 * text projects back to a span in the original body.
	 */
	public static function normalizeCommentBody(body: String): { text: String, map: Array<Int> } {
		final buf: StringBuf = new StringBuf();
		final map: Array<Int> = [];
		final n: Int = body.length;
		var i: Int = 0;
		while (i < n) {
			final c: Int = body.fastCodeAt(i);
			final crlf: Bool = c == '\r'.code && i + 1 < n && body.fastCodeAt(i + 1) == '\n'.code;
			if (c == '\n'.code || crlf) {
				final runStart: Int = i;
				i = skipContinuation(body, (crlf ? i + 1 : i) + 1, n);
				buf.addChar(' '.code);
				map.push(runStart);
			} else {
				buf.addChar(c);
				map.push(i);
				i++;
			}
		}
		map.push(n);
		return { text: buf.toString(), map: map };
	}

	/**
	 * Index of the first byte at or after `pos` that is neither whitespace nor inside a line or block
	 * comment. A comment nothing closes leaves no such byte: the result is then past the source end,
	 * which every caller's own bound test rejects.
	 */
	public static function skipForwardTrivia(source: String, pos: Int): Int {
		final n: Int = source.length;
		var i: Int = pos;
		while (i < n) {
			if (SourceText.isSpace(source.fastCodeAt(i))) {
				i++;
				continue;
			}
			final commentEnd: Int = commentRegionEnd(source, i);
			if (commentEnd < 0) break;
			i = commentEnd;
		}
		return i;
	}

	/**
	 * The offset just past the comment opening at `at`, or -1 when no comment opens there — the one
	 * comment scan behind `skipForwardTrivia`, `headerScan` and `isReturnTypeSlot`, each of which
	 * used to carry its own copy.
	 *
	 * A comment that NEVER CLOSES yields `source.length + 1`, one past every valid offset, so a
	 * caller's `> bound` test rejects it at ANY bound including the source end. That is what lets
	 * `isReturnTypeSlot` — whose `true` means "rewrite this" — fail closed on an unterminated `/*`
	 * while a cursor-advancing caller reads the same value as "trivia to the end" and stops.
	 *
	 * Bounding is the CALLER's job: the scan reads the whole of `source` and never clamps, because
	 * the three consumers bound it differently (a header range, a body start, the source end) and a
	 * clamp would make "closed exactly at the bound" indistinguishable from "never closed".
	 */
	public static function commentRegionEnd(source: String, at: Int): Int {
		if (at + 1 >= source.length || source.fastCodeAt(at) != '/'.code) return -1;
		final next: Int = source.fastCodeAt(at + 1);
		if (next == '*'.code) {
			final close: Int = source.indexOf('*/', at + 2);
			return close < 0 ? source.length + 1 : close + 2;
		}
		if (next != '/'.code) return -1;
		final nl: Int = source.indexOf('\n', at + 2);
		return nl < 0 ? source.length + 1 : nl + 1;
	}

	/** Extend a member's `span` back over own-line leading comments and forward over a same-line trailing comment, yielding its full source slot. */
	public static function memberTriviaSpan(source: String, span: Span, comments: Array<{ from: Int, to: Int, isLine: Bool }>): Span {
		final from: Int = absorbLeadingComments(source, comments, span.from);
		var to: Int = span.to;
		final t: Null<{ from: Int, to: Int, isLine: Bool }> = firstCommentStartingAfter(comments, to);
		if (t != null && source.substring(to, t.from).trim() == '' && source.substring(to, t.from).indexOf('\n') < 0) to = t.to;
		return new Span(from, to);
	}

	/**
	 * The start offset of the contiguous own-line comment block immediately preceding the
	 * line that contains `pos` (only whitespace between the comments and that line), or that
	 * line's start when none exists. Lets a reorder absorb a doc comment sitting just before
	 * a `#if` directive into the conditional it documents.
	 */
	public static function leadingCommentBlockStart(source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, pos: Int): Int {
		return absorbLeadingComments(source, comments, SourceText.lineStartOf(source, pos));
	}

	/**
	 * `lines` without its leading / trailing whitespace-only entries — the shared
	 * edge-trim behind `docComment`, `NewFile`'s `@@`-section bodies and the
	 * `fragmented-doc-comment` fix (internal blanks are kept).
	 */
	public static function trimBlankEdges(lines: Array<String>): Array<String> {
		final out: Array<String> = lines.copy();
		while (out.length > 0 && StringTools.trim(out[0]) == '') out.shift();
		while (out.length > 0 && StringTools.trim(out[out.length - 1]) == '') out.pop();
		return out;
	}

	/**
	 * The index of `line`'s GUTTER star, or -1 when it has none. A gutter star is followed by
	 * whitespace or nothing: `**BETA**` and `*emphasis*` open a gutter-less block's prose with a star
	 * that is not one, and reading only the first character reported every line of 109 such blocks in
	 * one library.
	 *
	 * Shared with `doc-comment-continuation`, which reports the lines this answer decides the prefix
	 * for. Written twice it is the one predicate in this pair that must not drift: the ops splice by
	 * it and that rule is the only gate that can see what they spliced.
	 */
	public static function gutterStarAt(line: String): Int {
		final lead: Int = line.length - line.ltrim().length;
		return line.fastCodeAt(lead) == '*'.code && (lead + 1 >= line.length || SourceText.isSpace(line.fastCodeAt(lead + 1))) ? lead : -1;
	}

	/**
	 * Whether a comment region carries a `noqa` suppression directive on any of
	 * its lines (`noqa` or `noqa: rules`, case-insensitive — the flake8 form the
	 * `Suppression` check honours). Such a line is machine-meaningful, so the
	 * rename must not rewrite inside it.
	 */
	public static function isNoqaComment(source: String, region: LexRegion): Bool {
		for (raw in source.substring(region.from, region.to).split('\n')) {
			var line: String = StringTools.trim(raw);
			if (line.startsWith('//') || line.startsWith('/*')) line = line.substr(2).trim();
			final lower: String = line.toLowerCase();
			if (lower == 'noqa' || lower.startsWith('noqa:')) return true;
		}
		return false;
	}

	/**
	 * The start offset of the BLOCK comment token whose end is exactly `end`, or -1 when
	 * no such token exists. `tokens` is a `collectCommentTokens` result, i.e. the lexer's
	 * own view: a block comment is ONE token from its opener to the first closer, so an
	 * opener sequence appearing inside the comment's text is content, not a boundary.
	 */
	public static function commentEndingAt(tokens: Array<{ from: Int, to: Int, isLine: Bool }>, end: Int, blockOnly: Bool): Int {
		for (t in tokens) if (t.to == end && !(blockOnly && t.isLine)) return t.from;
		return -1;
	}

	/**
	 * The continuation prefix ONE interior line of a block comment already uses: its own
	 * indentation, extended through the gutter star and the single space after it when the line
	 * carries one. A star followed by anything but whitespace is prose (`**BETA**`), not a
	 * gutter — the same discriminator `doc-comment-continuation` reports against.
	 */
	private static function interiorContinuation(line: String): String {
		final star: Int = gutterStarAt(line);
		return star < 0 ? line.substring(0, line.length - line.ltrim().length) : '${line.substring(0, star)}* ';
	}

	/**
	 * `line` with a continuation gutter the CALLER supplied stripped off — the leading
	 * whitespace, the `*`, and the single space that separates it from the text.
	 *
	 * This function owns the gutter, so a caller who also writes one gets it twice, and
	 * ` * \t * text` is a corruption no gate in this project can see: the writer re-emits a
	 * comment interior byte for byte, so the file stays writer-canonical and every node-based
	 * rule is blind to trivia. The op reports `wrote <file>` and the damage waits for a human
	 * to read the block. Stripping is the correction — the payload is PLAIN prose either way,
	 * and a caller who already knew that loses nothing.
	 *
	 * EXACTLY ONE space or tab may precede the star, because ` * ` and `\t * ` are the only two
	 * spellings this function and the writer ever emit. That is what keeps CONTENT reachable: a
	 * flush `* item` bullet survives, an indented `  * item` bullet survives, and a code sample's
	 * continuation line `        * b;` keeps both its indentation and its `*` operator. Stripping
	 * any leading whitespace run instead ate all three — a correction that destroys content is
	 * worse than the doubling it was written to prevent.
	 */
	private static function ungutter(line: String): String {
		var i: Int = 0;
		while (i < line.length && line.fastCodeAt(i) == '\t'.code) i++;
		// EXACTLY ONE space between the indent and the star: `<tabs> * ` and ` * ` are the only two
		// spellings this function and the writer ever emit.
		if (i + 1 >= line.length || line.fastCodeAt(i) != ' '.code || line.fastCodeAt(i + 1) != '*'.code) return line;
		final rest: String = line.substring(i + 2);
		return rest.length > 0 && (rest.fastCodeAt(0) == ' '.code || rest.fastCodeAt(0) == '\t'.code) ? rest.substring(1) : rest;
	}

	/** True if only whitespace precedes the byte at `from` on its line. */
	private static function isFullLineComment(source: String, from: Int): Bool {
		var i: Int = from - 1;
		while (i >= 0 && source.fastCodeAt(i) != '\n'.code) {
			if (!SourceText.isSpace(source.fastCodeAt(i))) return false;
			i--;
		}
		return true;
	}

	/**
	 * True if two comment tokens are full-line line comments separated by a
	 * single line break (no blank line, no code) — members of one contiguous
	 * line-comment block.
	 */
	private static function contiguousLineComments(
		source: String, a: { from: Int, to: Int, isLine: Bool }, b: { from: Int, to: Int, isLine: Bool }
	): Bool {
		if (!a.isLine || !b.isLine) return false;
		if (!isFullLineComment(source, a.from) || !isFullLineComment(source, b.from)) return false;
		var newlines: Int = 0;
		for (k in a.to ... b.from) {
			final c: Int = source.fastCodeAt(k);
			if (c == '\n'.code)
				newlines++;
			else if (!SourceText.isSpace(c))
				return false;
		}
		return newlines == 1;
	}

	/**
	 * Skip a comment line-continuation starting at `from` (just past a `\n`): any
	 * further whitespace and blank lines, plus ONE ` * ` doc-marker per line.
	 * Returns the index of the first content character (or `n`).
	 */
	private static function skipContinuation(body: String, from: Int, n: Int): Int {
		var i: Int = from;
		var markerSeen: Bool = false;
		while (i < n) {
			final c: Int = body.fastCodeAt(i);
			if (c == ' '.code || c == '\t'.code || c == '\r'.code) {
				i++;
			} else if (c == '\n'.code) {
				i++;
				markerSeen = false;
			} else if (c == '*'.code && !markerSeen) {
				i++;
				markerSeen = true;
			} else {
				break;
			}
		}
		return i;
	}

	/** Walk back from `from` over own-line line-comments and block-comments (and the whitespace between) to the first code. */
	private static function lastCommentEndingBefore(
		comments: Array<{ from: Int, to: Int, isLine: Bool }>, pos: Int
	): Null<{ from: Int, to: Int, isLine: Bool }> {
		var best: Null<{ from: Int, to: Int, isLine: Bool }> = null;
		for (c in comments) if (c.to <= pos && (best == null || c.to > best.to)) best = c;
		return best;
	}

	/** Extend `to` forward over a line-comment (or same-line block-comment) trailing on the decl's own line. */
	private static function firstCommentStartingAfter(
		comments: Array<{ from: Int, to: Int, isLine: Bool }>, pos: Int
	): Null<{ from: Int, to: Int, isLine: Bool }> {
		var best: Null<{ from: Int, to: Int, isLine: Bool }> = null;
		for (c in comments) if (c.from >= pos && (best == null || c.from < best.from)) best = c;
		return best;
	}

	/** Walk `from` back over own-line leading comments (and the whitespace between) to the first code; returns the new start offset. Shared by `memberTriviaSpan` and `leadingCommentBlockStart`. */
	private static function absorbLeadingComments(source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, from: Int): Int {
		var result: Int = from;
		while (true) {
			final c: Null<{ from: Int, to: Int, isLine: Bool }> = lastCommentEndingBefore(comments, result);
			if (c == null || source.substring(c.to, result).trim() != '') break;
			final ls: Int = SourceText.lineStartOf(source, c.from);
			if (source.substring(ls, c.from).trim() != '') break;
			result = ls;
		}
		return result;
	}

}

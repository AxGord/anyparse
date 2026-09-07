package anyparse.query;

using StringTools;
using Lambda;

import anyparse.check.CheckScan;
import anyparse.query.GrammarPlugin.LayoutMetrics;
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
	 * The line-comment opener — also the continuation marker every line after the first of a
	 * line-comment RUN carries, which is what `normalizeCommentBody` folds away in `lineRun` mode.
	 */
	private static final LINE_OPEN: String = '//';

	/**
	 * The block-comment gutter marker — one per continuation line, the default
	 * `normalizeCommentBody` folds.
	 */
	private static final GUTTER_STAR: String = '*';

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
	 * mistaken for a comment. The grouping itself lives in `collectCommentUnits`; this is a
	 * lookup into it for one cursor — and since a merged run is ONE span, a cursor in the
	 * whitespace BETWEEN two of its lines now resolves to the run, where the per-token walk
	 * this replaced answered null.
	 */
	public static function commentBlockAt(source: String, cursor: Int, regions: Array<LexRegion>): Null<Span> {
		final units: Array<{ from: Int, to: Int, isLine: Bool }> = collectCommentUnits(source, regions);
		final unit: Null<{ from: Int, to: Int, isLine: Bool }> = units.find(u -> cursor >= u.from && cursor < u.to);
		return unit == null ? null : new Span(unit.from, unit.to);
	}

	/**
	 * `span` with leading and trailing TRIVIA — whitespace, and any byte inside one of
	 * `comments` — cut off, or the empty span at `span.from` when it holds nothing else.
	 *
	 * A comment is not code the model dropped, it is code no PROJECTION carries: the tree has no
	 * comment node anywhere, inside a conditional-compilation region or out of it. So a byte range
	 * built from "what no child covers" reads a comment as unmodelled, and a diagnostic quoting
	 * that range runs past the construct it names into the next statement's comment. Measured over
	 * the two real trees `fmt` reaches, that is 1 region of 59 — cosmetic, and only at the ENDS: a
	 * comment WITHIN the range is content the quote must keep, which is why this trims rather than
	 * filters.
	 *
	 * Whitespace goes with it so the two rules cannot disagree about a range ending
	 * `#end\n\t// note`: stopping at the newline would leave the comment standing, stopping at the
	 * comment would leave the newline.
	 */
	public static function trimTrivia(source: String, span: Span, comments: Array<{ from: Int, to: Int, isLine: Bool }>): Span {
		var from: Int = span.from;
		var to: Int = span.to;
		while (from < to) {
			if (isSpaceAt(source, from)) {
				from++;
				continue;
			}
			final token: Null<{ from: Int, to: Int, isLine: Bool }> = enclosingComment(comments, from);
			if (token == null) break;
			from = token.to < to ? token.to : to;
		}
		while (to > from) {
			if (isSpaceAt(source, to - 1)) {
				to--;
				continue;
			}
			final token: Null<{ from: Int, to: Int, isLine: Bool }> = enclosingComment(comments, to - 1);
			if (token == null) break;
			to = token.from > from ? token.from : from;
		}
		return new Span(from, to);
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
	 * The comment UNITS of one source — one entry per logically single body, in source order: a
	 * block comment as it stands, a run of contiguous full-line `//` comments merged into ONE
	 * `{ from, to, isLine: true }` reaching from the first opener to the last line's end, and a
	 * `//` trailing after code on its own.
	 *
	 * The lexer's tokens (`collectCommentTokens`) are one per LINE for `//`, which is right for
	 * every consumer that masks or measures BYTES and wrong for the one that matches TEXT: a find
	 * spanning two `//` lines could never match, because no single body held both, and
	 * `comment-rewrite` answered that the text was absent from the file. `commentBlockAt` already
	 * carried this grouping rule for one cursor; this is the same rule over the whole file, and
	 * that function is now a lookup into it.
	 */
	public static function collectCommentUnits(source: String, regions: Array<LexRegion>): Array<{ from: Int, to: Int, isLine: Bool }> {
		final toks: Array<{ from: Int, to: Int, isLine: Bool }> = collectCommentTokens(regions);
		final out: Array<{ from: Int, to: Int, isLine: Bool }> = [];
		var i: Int = 0;
		while (i < toks.length) {
			final head: { from: Int, to: Int, isLine: Bool } = toks[i];
			final merge: Bool = head.isLine && isFullLineComment(source, head.from);
			var last: Int = i;
			while (merge && last + 1 < toks.length && contiguousLineComments(source, toks[last], toks[last + 1])) last++;
			out.push(last == i ? head : { from: head.from, to: toks[last].to, isLine: true });
			i = last + 1;
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
	 * The text that precedes a comment's BODY on the comment's own line, opener included — the
	 * indentation plus `//` for a line comment or for the first line of a merged run, whatever code
	 * stands to the left plus `/*` for a block that opens after something else.
	 *
	 * The body's first line is the ONE line whose rendered width the body does not carry:
	 * `commentBody` starts two characters past the opener, so a width measurement over the body
	 * alone calls that line short by the opener and everything left of it.
	 */
	public static function commentHead(source: String, tok: { from: Int, to: Int, isLine: Bool }): String {
		return source.substring(SourceText.lineStartOf(source, tok.from), tok.from + 2);
	}

	/**
	 * Whether the raw comment body range `[from, to)` holds a PARAGRAPH SEPARATOR it does not merely
	 * OPEN with — a line continuation whose skipped run crosses a blank continuation line (a bare
	 * `//` inside a run, a bare ` *` inside a block).
	 *
	 * `normalizeCommentBody` folds such a run into the SAME single space an ordinary line break
	 * becomes, so a literal find reads `A B` across `A`, a blank line and `B`, matches, and the
	 * splice then DELETES the separator — two paragraphs become one line with no diagnostic.
	 * Measured on `HxCasePattern.hx`: the bare `\t//` on line 56 vanished and lines 55 and 57 became
	 * one 125-column line, inside the configured 140, so the width gate never fired either.
	 *
	 * `from` is always CONTENT, never a break: a match beginning on a folded break has a leading
	 * space in its needle, and `literalReplace`'s leading-boundary rule then moves `from` past the
	 * whole run before asking. A guard for that case here was dead code, and its absence is why this
	 * function reports every separator in the range rather than "interior" ones by position.
	 */
	public static function interiorParagraphBreak(body: String, from: Int, to: Int, lineRun: Bool): Bool {
		final marker: String = lineRun ? LINE_OPEN : GUTTER_STAR;
		final n: Int = body.length;
		var i: Int = from;
		while (i < to) {
			final c: Int = body.fastCodeAt(i);
			final crlf: Bool = c == '\r'.code && i + 1 < n && body.fastCodeAt(i + 1) == '\n'.code;
			if (c != '\n'.code && !crlf) {
				i++;
				continue;
			}
			final start: Int = (crlf ? i + 1 : i) + 1;
			final next: Int = skipContinuation(body, start, n, marker);
			// A second break inside one skipped run means a line went by carrying nothing but its
			// marker — the blank line that IS the paragraph separator.
			for (k in start ... next) if (body.fastCodeAt(k) == '\n'.code) return true;
			i = next;
		}
		return false;
	}

	/**
	 * `body` with the lines the edit made TOO WIDE broken back at spaces into lines carrying
	 * `continuation`, and every other line byte-identical. `was` is the body before the edit.
	 *
	 * WHY the op reflows at all: a literal find crossing a comment line break replaces that break
	 * along with the text around it, so the two lines JOIN — which is the whole T755 scenario (fix a
	 * phrase spread over two `//` lines) and left one over-long line the width gate refused every
	 * time the join passed the configured width. Measured on `WriterRefFieldLowering.hx`: 169
	 * columns against 140. Being able to FIND the text was never the same as being able to edit it
	 * in place.
	 *
	 * It is a REPAIR, not a restyling, and the trigger says so: unless the edit GAINED an over-width
	 * line — more of them, or a wider widest, the same comparison the caller's width gate makes —
	 * the body comes back untouched. Without that test a seven-character SHORTENING edit inside one
	 * of this tree's 210 inherited over-width comment lines re-wrapped the whole paragraph:
	 * `MemberOrder.hx` went 980 lines to 1029 for an edit the old gate accepted outright.
	 *
	 * `head` is what precedes the body on its own line (`commentHead`), because the body's first
	 * line is the one line whose width the body does not carry. A line the edit left byte-identical
	 * is never wrapped either, so an inherited long line inside a block the edit DID break keeps its
	 * own style. A line with no space inside its budget is handed back over-width — the caller's
	 * width gate is then the only thing that can name it, and that is the one outcome a reflow
	 * cannot repair.
	 *
	 * A blank continuation line's width IS its prefix, so it is kept by construction: a paragraph
	 * separator survives the reflow rather than being filled into its neighbours. Nothing here ever
	 * JOINS two lines, which is what keeps the caller's own line breaks intact. What layout it must
	 * not touch at all is `reflowSafeLine`'s question.
	 */
	public static function wrapCommentBody(
		body: String, was: String, head: String, continuation: String, metrics: LayoutMetrics, lineRun: Bool
	): String {
		final width: Int = metrics.lineWidth;
		final tab: Int = metrics.indentWidth;
		final lines: Array<String> = body.split('\n');
		final keep: Array<String> = was.split('\n');
		final got: Array<Int> = overWidthColumns(lines, head, width, tab);
		final had: Array<Int> = overWidthColumns(keep, head, width, tab);
		if (got.length <= had.length && widestColumn(got) <= widestColumn(had)) return body;
		final out: Array<String> = [];
		final contCols: Int = CheckScan.displayColumn(continuation, 0, continuation.length, tab);
		final headHasCode: Bool = head.trim().length > 2;
		for (i => raw in lines) {
			final cr: Bool = raw.length > 0 && raw.fastCodeAt(raw.length - 1) == '\r'.code;
			final line: String = cr ? raw.substring(0, raw.length - 1) : raw;
			final lead: String = i == 0 ? head : '';
			final leadCols: Int = CheckScan.displayColumn(lead, 0, lead.length, tab);
			final at: Int = i == 0 ? openerBodyPrefix(line, head) : linePrefixLength(line, lineRun);
			final wrappable: Bool = !keep.contains(raw) && !(i == 0 && headHasCode) && reflowSafeLine(line.substring(at));
			if (!wrappable || leadCols + CheckScan.displayColumn(line, 0, line.length, tab) <= width) {
				out.push(raw);
				continue;
			}
			final prefix: String = line.substring(0, at);
			final firstCols: Int = leadCols + CheckScan.displayColumn(prefix, 0, prefix.length, tab);
			final chunks: Array<String> = wrapText(line.substring(at), firstCols, contCols, width, tab);
			for (k => chunk in chunks) out.push((k == 0 ? prefix : continuation) + chunk + (cr ? '\r' : ''));
		}
		return out.join('\n');
	}

	/**
	 * Whether one comment line's post-prefix `text` is prose a reflow may re-lay-out, rather than
	 * layout that carries its own meaning.
	 *
	 * Every shape refused here is one whose wrapped form is a CORRUPTION no gate in this project can
	 * see — the writer re-emits a comment interior byte for byte, so `fmt --list` stays clean and no
	 * rule reads a comment's shape. Measured, each on a real edit that pushed its line past the
	 * width:
	 *
	 *  - a SUPPRESSION directive. `Suppression.parseNoqa` reads an empty rule list as EVERY rule, so
	 *    breaking `// noqa: some-rule` after the colon silently turns one exemption into a blanket
	 *    one: a live `naming` warning disappeared and lint reported it as an improvement. 24 of this
	 *    tree's 131 trailing noqa comments are already past 120 columns.
	 *  - INDENTATION the author wrote. `CommentStyle`'s own rule is that whitespace beyond the
	 *    block's common prefix is the author's and survives; a wrapped code sample loses its hanging
	 *    indent to the bare continuation.
	 *  - a MARKDOWN block marker. A table row split mid-row loses its cell count; a `- ` bullet's
	 *    continuation, laid out at the bare gutter, reads as a sibling paragraph between two bullets.
	 *
	 * A refused line stays over-width and the caller's width gate names it, which is the honest end
	 * state: the op cannot re-lay-out this line, and says so instead of guessing.
	 */
	public static function reflowSafeLine(text: String): Bool {
		if (text.length == 0) return false;
		final head: Int = text.fastCodeAt(0);
		if (head == ' '.code || head == '\t'.code) return false;
		final lower: String = text.toLowerCase();
		if (lower.startsWith('noqa') || lower.startsWith('checkstyle:')) return false;
		if (head == '|'.code || head == '>'.code || head == '#'.code) return false;
		if (text.length > 1 && text.fastCodeAt(1) == ' '.code && (head == '-'.code || head == '+'.code || head == '*'.code)) return false;
		var digits: Int = 0;
		while (digits < text.length && text.fastCodeAt(digits) >= '0'.code && text.fastCodeAt(digits) <= '9'.code) digits++;
		return !(digits > 0 && digits + 1 < text.length && text.fastCodeAt(digits) == '.'.code && text.fastCodeAt(digits + 1) == ' '.code);
	}

	/**
	 * `body` with every line that holds nothing but its continuation prefix rtrimmed to the bare
	 * prefix.
	 *
	 * `reflowIntoComment` and `openGrownDocBlock` both do this to their own output and for the same
	 * reason: the writer re-emits a comment interior byte for byte, so a trailing space survives in a
	 * project whose `hxformat.json` sets `indentation.trailingWhitespace: false`, and `fmt --list`
	 * still calls the file canonical. The path that did NOT do it is a DELETION — an empty
	 * replacement consumes a paragraph's text and leaves ` * ` where the text was, measured on a
	 * three-paragraph block. Making the rule uniform is what this is; it is not a new policy.
	 */
	public static function trimPrefixOnlyLines(body: String): String {
		final lines: Array<String> = body.split('\n');
		var changed: Bool = false;
		for (i => line in lines) {
			final kept: String = line.rtrim();
			// The line has to END on a marker. A body's LAST line is the whitespace carrying the
			// closer's indentation, and rtrimming that put `*\/` flush against column 0.
			if (kept == line || !kept.endsWith(GUTTER_STAR) && !kept.endsWith(LINE_OPEN)) continue;
			lines[i] = kept;
			changed = true;
		}
		return changed ? lines.join('\n') : body;
	}

	/**
	 * Normalize a comment BODY for cross-line literal matching: fold each line
	 * continuation — a `\n` or `\r\n`, the following whitespace, blank lines, and
	 * one continuation marker per line — into a single space, so a phrase wrapped
	 * across two lines reads as one run. `lineRun` picks the marker — the gutter star of a
	 * block comment, the `//` opener when the body is a run of line comments merged by
	 * `collectCommentUnits`. It is REQUIRED and not defaulted: a caller who forgets it would
	 * silently get block semantics for a run, which is the shape arm `M-COMMENT-MARKER-FORCED`
	 * exists to catch. Returns the normalized text plus a
	 * `map` from each normalized index to the original body offset it came from,
	 * with `map[text.length] == body.length`, so a match found in the normalized
	 * text projects back to a span in the original body.
	 */
	public static function normalizeCommentBody(body: String, lineRun: Bool): { text: String, map: Array<Int> } {
		final marker: String = lineRun ? LINE_OPEN : GUTTER_STAR;
		final buf: StringBuf = new StringBuf();
		final map: Array<Int> = [];
		final n: Int = body.length;
		var i: Int = 0;
		while (i < n) {
			final c: Int = body.fastCodeAt(i);
			final crlf: Bool = c == '\r'.code && i + 1 < n && body.fastCodeAt(i + 1) == '\n'.code;
			if (c == '\n'.code || crlf) {
				final runStart: Int = i;
				i = skipContinuation(body, (crlf ? i + 1 : i) + 1, n, marker);
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

	/** Whether the byte at `at` is a space, tab, carriage return or newline. */
	private static inline function isSpaceAt(source: String, at: Int): Bool {
		final code: Int = source.fastCodeAt(at);
		return code == ' '.code || code == '\t'.code || code == '\n'.code || code == '\r'.code;
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
	 * further whitespace and blank lines, plus ONE `marker` per line — the gutter star of a block, or the `//` opener
	 * every line after the first of a line-comment RUN carries. Returns the index
	 * of the first content character (or `n`).
	 */
	private static function skipContinuation(body: String, from: Int, n: Int, marker: String): Int {
		var i: Int = from;
		var markerSeen: Bool = false;
		while (i < n) {
			final c: Int = body.fastCodeAt(i);
			if (c == ' '.code || c == '\t'.code || c == '\r'.code) {
				i++;
			} else if (c == '\n'.code) {
				i++;
				markerSeen = false;
			} else if (!markerSeen && body.substr(i, marker.length) == marker) {
				i += marker.length;
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

	/** The comment token of `comments` covering `at`, or null when that byte is not inside one. */
	private static function enclosingComment(
		comments: Array<{ from: Int, to: Int, isLine: Bool }>, at: Int
	): Null<{ from: Int, to: Int, isLine: Bool }> {
		return comments.find(token -> token.from <= at && at < token.to);
	}

	/**
	 * How many characters of one INTERIOR comment line are its continuation prefix — the
	 * indentation, the marker, and the single space after it. `lineRun` picks the marker the way
	 * `normalizeCommentBody` does: the `//` opener of a merged run, the gutter star otherwise.
	 *
	 * A gutter-less block line carries only its indentation, and `ungutter` answers that by handing
	 * the line back unchanged — it owns the "exactly one space before the star" rule that keeps a
	 * `* item` bullet and a code sample's `* b;` reachable, so the prefix is read through it rather
	 * than by a second whitespace scan that would disagree.
	 */
	private static function linePrefixLength(line: String, lineRun: Bool): Int {
		if (!lineRun) {
			final bare: String = ungutter(line);
			return bare.length == line.length ? line.length - line.ltrim().length : line.length - bare.length;
		}
		var i: Int = 0;
		while (i < line.length && (line.fastCodeAt(i) == ' '.code || line.fastCodeAt(i) == '\t'.code)) i++;
		if (line.substr(i, LINE_OPEN.length) != LINE_OPEN) return i;
		i += LINE_OPEN.length;
		return i < line.length && line.fastCodeAt(i) == ' '.code ? i + 1 : i;
	}

	/**
	 * `text` broken at spaces into the chunks of one wrapped comment line: the first laid out behind
	 * `firstCols` rendered columns, every later one behind `contCols`, none past `width`.
	 *
	 * The width it actually wraps at is the NARROWEST that costs the same number of lines as
	 * `width` does. Filling greedily to the limit is correct and reads wrong: the T698 join, broken
	 * at the configured 140, left a 137-column line followed by a 42-column orphan inside a run
	 * whose other lines are 82 — a shape a reviewer flags and the author would rather have avoided
	 * the op for. Balanced, the same two lines come out at 86 and 93.
	 *
	 * A remainder with no space inside its budget is emitted WHOLE and over-width rather than cut
	 * mid-word: a 180-character identifier or URL is not a wrapping problem, and splitting it would
	 * change the text. That short-circuit is also why the narrowest width is found by scanning up
	 * from an estimate rather than by bisecting — at a small enough limit `fillText` stops finding
	 * break points and the line COUNT falls again, so the predicate is not monotone and a bisection
	 * would converge on one unwrappable line.
	 */
	private static function wrapText(text: String, firstCols: Int, contCols: Int, width: Int, tab: Int): Array<String> {
		final greedy: Array<String> = fillText(text, firstCols, contCols, width, tab);
		final lines: Int = greedy.length;
		if (lines < 2) return greedy;
		final lead: Int = firstCols > contCols ? firstCols : contCols;
		final start: Int = lead + Math.ceil(CheckScan.displayColumn(text, 0, text.length, tab) / lines);
		final ceiling: Int = widestChunk(greedy, firstCols, contCols, tab);
		for (limit in (start < 1 ? 1 : start) ... width) {
			final balanced: Array<String> = fillText(text, firstCols, contCols, limit, tab);
			// The LINE COUNT alone is not the test, because `fillText` short-circuits: below the first
			// token's own width it stops finding break points and hands the remainder back whole, so the
			// count FALLS and a one-line over-width answer beats a legal two-line one. Measured: an
			// 86-character URL followed by prose was refused at 145 columns while the same body with the
			// space at index 60 wrapped at 150. The candidate must also be no WIDER than greedy.
			if (balanced.length <= lines && widestChunk(balanced, firstCols, contCols, tab) <= ceiling) return balanced;
		}
		return greedy;
	}

	/**
	 * `text` filled greedily to `limit` columns, the first chunk behind `firstCols` and the rest
	 * behind `contCols`. Trailing whitespace at a break point goes with the break — the project's
	 * own `hxformat.json` forbids it and the writer re-emits a comment interior verbatim, so nothing
	 * downstream would remove it.
	 */
	private static function fillText(text: String, firstCols: Int, contCols: Int, limit: Int, tab: Int): Array<String> {
		final chunks: Array<String> = [];
		var start: Int = 0;
		var avail: Int = limit - firstCols;
		while (true) {
			if (avail > 0 && CheckScan.displayColumn(text, start, text.length, tab) <= avail) {
				chunks.push(text.substring(start));
				break;
			}
			var cut: Int = -1;
			var cols: Int = 0;
			var i: Int = start;
			while (i < text.length) {
				cols += text.fastCodeAt(i) == '\t'.code ? tab : 1;
				if (cols > avail) break;
				if (i > start && text.fastCodeAt(i) == ' '.code) cut = i;
				i++;
			}
			if (cut < 0) {
				chunks.push(text.substring(start));
				break;
			}
			chunks.push(text.substring(start, cut).rtrim());
			start = cut + 1;
			while (start < text.length && text.fastCodeAt(start) == ' '.code) start++;
			avail = limit - contCols;
		}
		return chunks;
	}

	/**
	 * The rendered column width of every line of `lines` that runs past `width`, in order. `head` is
	 * what precedes line 0 on its own line, which is the one line the body does not carry.
	 *
	 * The pair with `widestColumn` is the same COUNT-and-WIDEST comparison `CommentRewrite`'s width
	 * gate makes over the whole file, asked here of one comment unit: it is what lets the reflow fire
	 * only where the edit actually broke something, rather than restyling every block it touches.
	 */
	private static function overWidthColumns(lines: Array<String>, head: String, width: Int, tab: Int): Array<Int> {
		final out: Array<Int> = [];
		for (i => raw in lines) {
			final line: String = raw.length > 0 && raw.fastCodeAt(raw.length - 1) == '\r'.code ? raw.substring(0, raw.length - 1) : raw;
			final lead: String = i == 0 ? head : '';
			final cols: Int = CheckScan.displayColumn(lead, 0, lead.length, tab) + CheckScan.displayColumn(line, 0, line.length, tab);
			if (cols > width) out.push(cols);
		}
		return out;
	}

	/** The largest of `columns`, 0 when there is none. */
	private static function widestColumn(columns: Array<Int>): Int {
		var best: Int = 0;
		for (cols in columns) if (cols > best) best = cols;
		return best;
	}

	/** The widest rendered line `chunks` would produce behind `firstCols` and then `contCols`. */
	private static function widestChunk(chunks: Array<String>, firstCols: Int, contCols: Int, tab: Int): Int {
		var best: Int = 0;
		for (k => chunk in chunks) {
			final cols: Int = (k == 0 ? firstCols : contCols) + CheckScan.displayColumn(chunk, 0, chunk.length, tab);
			if (cols > best) best = cols;
		}
		return best;
	}

	/**
	 * How many characters of the body's FIRST line belong to the opener rather than to the text: the
	 * doc block's second star, and the single space that separates any opener from its prose.
	 *
	 * `commentBody` starts two characters past `//` or `/*`, so line 0 arrives carrying the pieces
	 * every other line hands to `linePrefixLength`. Reading it as text instead is what made
	 * `reflowSafeLine` see the standard space after `//` as the author's own indentation and refuse
	 * every first line, and the `/**`'s second star as a markdown bullet.
	 */
	private static function openerBodyPrefix(line: String, head: String): Int {
		var i: Int = 0;
		if (head.endsWith('/*') && line.length > 0 && line.fastCodeAt(0) == '*'.code) i++;
		return i < line.length && line.fastCodeAt(i) == ' '.code ? i + 1 : i;
	}

}

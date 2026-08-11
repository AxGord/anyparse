package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using StringTools;

/** One comment token as `RefactorSupport.collectCommentTokens` yields it: its span, and whether it is a `//` line comment. */
private typedef CommentToken = {
	var from: Int;
	var to: Int;
	var isLine: Bool;
}
/**
 * Flags a content-free comment — a line comment with only whitespace after the
 * slashes, an empty block comment, or an empty doc comment (including a multi-line
 * one whose interior is only stars and whitespace). Deliberate divider runs (dashed
 * rules), directive comments (noqa), PARAGRAPH SEPARATORS (below), and any printable
 * content are kept; conditional-compilation lines are not comments and never match.
 * `Warning`.
 *
 * ## Detection
 *
 * A pure comment-token scan (no parse needed) over `RefactorSupport.collectCommentTokens`,
 * which is string-aware — a slash-slash inside a STRING literal is never visited. A
 * line comment is empty when every unit after the slashes is whitespace; a block or
 * doc comment when it is closed and its interior between the delimiters is only
 * whitespace and stars.
 *
 * ## The paragraph separator — content-free, and NOT noise
 *
 * A bare `//` on its own line, with a comment-only line directly above it and another
 * directly below, is the blank line of a `//` prose block. It carries no characters and
 * every content test calls it empty, but deleting it MERGES two paragraphs — a change to
 * what the comment SAYS, not a cleanup. It is kept, for the same reason a dashed divider
 * run is: the emptiness is the point.
 *
 * That is not a marginal shape. Measured over this repository's own 636 files, ALL 136
 * findings the rule produced without this gate were paragraph separators and none was
 * stray noise — an autofix would have silently reflowed 136 prose blocks. (The reference
 * project reports none either way; it writes its multi-paragraph prose as doc comments,
 * whose interiors this rule never inspects.)
 *
 * The criterion is positive and purely lexical: the empty comment and BOTH neighbours are
 * line comments, each alone on its line, on three CONSECUTIVE lines, and the one ABOVE
 * carries content. A bare `//` at the head or tail of a run has nothing on one side to
 * separate and stays flagged — that one is padding. So does one whose neighbour shares its
 * line with code, or is a block comment (a block carries its paragraph breaks inside
 * itself), or sits a blank line away (the blank already separates).
 *
 * The content clause on the line above is what keeps a RUN of blank `//` lines reachable.
 * Without it each blank of a run saw another blank beside it, every one was kept, and the
 * padding was unreducible. One-sided is the correct side: in `// a` `//` `//` `// b` only
 * the first blank has content above it, so exactly one separator survives and the extra
 * padding reports. Requiring content on BOTH sides would flag every blank of the run and
 * let the fix merge the paragraphs.
 *
 * ## Fix
 *
 * `fix` deletes each flagged comment. A comment alone on its line(s) takes the whole
 * physical line(s) with it (no blank residue); a comment trailing code is stripped and
 * the code line rtrimmed; a comment with code after it on the same line is removed on
 * its own. The edits are the raw deletions the caller batches into one
 * `RefactorSupport.canonicalize` per file.
 */
@:nullSafety(Strict)
final class EmptyComment implements Check {

	public function new() {}

	public function id(): String {
		return 'empty-comment';
	}

	public function description(): String {
		return 'an empty comment (a content-free // or /* */)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final violations: Array<Violation> = [];
		for (entry in files) scan(violations, entry.file, entry.source);
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) edits.push({ span: deletionSpan(source, span), text: '' });
		}
		return edits;
	}

	/** Whether code unit `c` is horizontal or vertical whitespace. */
	private static inline function isWs(c: Int): Bool {
		return c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
	}

	/** Scan every comment token in `source`, flagging each content-free one that is not a paragraph separator. */
	private static function scan(out: Array<Violation>, file: String, source: String): Void {
		final toks: Array<CommentToken> = RefactorSupport.collectCommentTokens(source);
		for (i => tok in toks) if (isEmpty(source, tok) && !isParagraphSeparator(source, toks, i)) out.push({
			file: file,
			span: new Span(tok.from, tok.to),
			rule: 'empty-comment',
			severity: Severity.Warning,
			message: 'empty comment'
		});
	}

	/**
	 * Whether the empty comment at `toks[i]` is a paragraph separator inside a `//` prose
	 * block — see the class doc for why such a comment is kept.
	 *
	 * Every clause is a positive requirement, so an unlisted shape fails by construction:
	 * this token and both its NEIGHBOURS in the comment stream are LINE comments, each
	 * alone on its line, and the three sit on consecutive lines. Neighbours are read from
	 * the token stream rather than the raw text, so a slash-slash inside a string literal
	 * can never stand in for one (`collectCommentTokens` is string-aware).
	 *
	 * The neighbour must also carry CONTENT. Without that clause a RUN of blank `//` lines
	 * inside a prose block was unreachable in both directions at once — each blank saw
	 * another blank beside it and every one was kept, so `// a` `//` `//` `// b` could
	 * never be reduced. The clause is one-sided on purpose: only the FIRST blank of the
	 * run has content on its left, so exactly it is kept and the rest report, which is the
	 * separator the author meant plus the padding they did not. Requiring content on BOTH
	 * sides would be the opposite error — every blank of the run would report, and the fix
	 * would merge the two paragraphs outright.
	 */
	private static function isParagraphSeparator(source: String, toks: Array<CommentToken>, i: Int): Bool {
		if (i == 0 || i + 1 >= toks.length) return false;
		final tok: CommentToken = toks[i];
		final prev: CommentToken = toks[i - 1];
		final next: CommentToken = toks[i + 1];
		return tok.isLine && prev.isLine && next.isLine && !isEmpty(source, prev) && aloneOnLine(source, tok.from)
			&& aloneOnLine(source, prev.from) && aloneOnLine(source, next.from) && oneLineApart(source, prev.to, tok.from)
			&& oneLineApart(source, tok.to, next.from);
	}

	/** Whether only whitespace separates `from` from the start of its line — the comment opens the line. */
	private static function aloneOnLine(source: String, from: Int): Bool {
		var i: Int = from;
		while (i > 0) {
			final c: Int = source.fastCodeAt(i - 1);
			if (c == '\n'.code) return true;
			if (c != ' '.code && c != '\t'.code && c != '\r'.code) return false;
			i--;
		}
		return true;
	}

	/** Whether the gap `[gapStart, gapEnd)` between two tokens is whitespace holding EXACTLY one newline — they sit on consecutive lines. */
	private static function oneLineApart(source: String, gapStart: Int, gapEnd: Int): Bool {
		var newlines: Int = 0;
		for (i in gapStart ... gapEnd) {
			final c: Int = source.fastCodeAt(i);
			if (c == '\n'.code)
				newlines++
			else if (!isWs(c))
				return false;
		}
		return newlines == 1;
	}

	/**
	 * Whether the comment token is content-free: a line comment with only whitespace
	 * after the slashes, or a closed block/doc comment whose interior between the
	 * delimiters is only whitespace and stars (doc gutters). An unclosed block comment
	 * is never treated as empty.
	 */
	private static function isEmpty(source: String, tok: CommentToken): Bool {
		if (!tok.isLine) return RefactorSupport.blockCommentIsBlank(source, tok);
		for (i in tok.from + 2...tok.to) if (!isWs(source.fastCodeAt(i))) return false;
		return true;
	}

	/**
	 * The span to delete for the empty comment at `span`. Alone on its line(s) (only
	 * whitespace around it) → the whole physical line(s), so the batched re-emit leaves
	 * no blank residue; trailing code with only whitespace after → the comment plus the
	 * whitespace before it (rtrimming the code line); code after it on the same line →
	 * only the comment itself.
	 */
	private static function deletionSpan(source: String, span: Span): Span {
		var lineStart: Int = span.from;
		while (lineStart > 0 && source.fastCodeAt(lineStart - 1) != '\n'.code) lineStart--;
		var lineEnd: Int = span.to;
		while (lineEnd < source.length && source.fastCodeAt(lineEnd) != '\n'.code) lineEnd++;
		final codeBefore: Bool = source.substring(lineStart, span.from).trim() != '';
		final codeAfter: Bool = source.substring(span.to, lineEnd).trim() != '';
		if (!codeBefore && !codeAfter) return RefactorSupport.lineExtendedSpan(source, span);
		if (codeAfter) return span;
		var from: Int = span.from;
		while (from > lineStart) {
			final c: Int = source.fastCodeAt(from - 1);
			if (c == ' '.code || c == '\t'.code)
				from--
			else
				break;
		}
		return new Span(from, span.to);
	}

}

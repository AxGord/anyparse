package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.FragmentedDocComment.CommentTok;
import anyparse.query.GrammarPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * One tag section of a doc comment: the tag's `name`, the byte span reported as the
 * violation (`from` at the `@`, `to` at the end of the section's last line), and the
 * interior physical-line range it occupies (the tag line plus its continuation lines).
 */
typedef TagSection = {
	final name: String;
	final from: Int;
	final to: Int;
	final firstLine: Int;
	final lastLine: Int;
};

/**
 * Flags a doc-comment tag that carries no description - a name-only `@param str`, which
 * merely restates the signature, or a bare `@return` / `@returns` / `@throws` /
 * `@exception` / `@see`. Zero information, so `Warning`. Any text after the tag, or on one
 * of its continuation lines, is documentation and is kept; so is `@throws SomeType`, whose
 * type a Haxe signature does not carry. Every other tag is kept by construction - the
 * whitelist above is the whole detection surface.
 *
 * ## Detection
 *
 * A pure comment-token scan (no parse needed) over `RefactorSupport.collectCommentTokens`,
 * which is string-aware. Only a CLOSED block comment opening with the doc marker is a doc;
 * a plain block comment and an unclosed one never match. The interior is split into
 * physical lines and each line's bare content taken past its leading whitespace, its
 * gutter star run, and the whitespace after it. A line whose bare content opens with `@`
 * plus letters, terminated by whitespace or the line end, starts a section that runs to
 * the next such line or to the interior end.
 *
 * ## Fix
 *
 * `fix` deletes each flagged section's whole physical line(s). Deletion applies a STRICTER
 * gutter test than detection: a line is deletable only when it is empty or carries a single
 * gutter star, so a deliberate multi-star divider is content the fix never swallows, even
 * inside a section detection read as content-free. When the deletions would leave nothing
 * but deletable gutter lines behind, the entire comment goes instead, taking its own
 * line(s) with it (the `empty-comment` deletion-span rule). Gutter lines stranded before
 * the closing delimiter are swallowed too, so no residue survives; when the closer shares
 * its line with a flagged tag, only that line's content goes and the closer stays put. The
 * opener, the closer and every kept line are untouched - the caller batches the edits
 * through `RefactorSupport.canonicalize`, which re-normalises the doc's shape.
 *
 * Protecting the divider can leave a doc whose whole interior IS that divider. This rule
 * stops there, and `empty-comment` removes such a doc on the next fixed-point pass -
 * consistent with existing semantics, since `RefactorSupport.blockCommentIsBlank` has always
 * read a stars-only interior as blank; the doc survived earlier only because the tag's
 * letters made it non-blank, and a divider on its own documents nothing.
 *
 * Deleting a member's ONLY doc comment - a lone bare-`@return` doc, say - turns a member
 * that satisfied `doc-coverage` into a `doc-coverage` violation. That is intended: the doc
 * documented nothing, so the report now names a real gap. It cannot oscillate either,
 * since `doc-coverage` has no fix.
 */
@:nullSafety(Strict)
final class EmptyDocTag implements Check {

	/** The doc-comment opener - a plain block comment carries no tags. */
	private static final DOC_OPEN: String = '/**';

	/** The block-comment closer. */
	private static final DOC_CLOSE: String = '*/';

	public function new() {}

	public function id(): String {
		return 'empty-doc-tag';
	}

	public function description(): String {
		return 'a doc-comment tag with no description (name-only @param, bare @return)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final violations: Array<Violation> = [];
		for (entry in files) scan(violations, entry.file, entry.source);
		return violations;
	}

	/**
	 * Delete every flagged section, or the whole comment when nothing but deletable gutter
	 * lines would survive it. `violations` may be a subset of what `run` reported, so the
	 * sections are recomputed and matched against the flagged spans.
	 */
	@:access(anyparse.check.EmptyComment)
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final flagged: Array<Int> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push(span.from);
		}
		final edits: Array<{ span: Span, text: String }> = [];
		for (tok in RefactorSupport.collectCommentTokens(source)) if (isDoc(source, tok)) {
			final lines: Array<Span> = interiorLines(source, tok);
			final doomed: Array<TagSection> = emptySections(source, lines).filter(s -> flagged.contains(s.from));
			if (doomed.length > 0) {
				final mark: Array<Bool> = deletableLines(source, lines, doomed);
				if (survivorsBlank(source, lines, mark))
					edits.push({ span: EmptyComment.deletionSpan(source, new Span(tok.from, tok.to)), text: '' });
				else
					for (span in deletionSpans(source, lines, mark)) edits.push({ span: span, text: '' });
			}
		}
		return edits;
	}

	/** Scan every doc comment in `source`, flagging each content-free tag section. */
	private static function scan(out: Array<Violation>, file: String, source: String): Void {
		for (tok in RefactorSupport.collectCommentTokens(source)) if (isDoc(source, tok)) {
			final lines: Array<Span> = interiorLines(source, tok);
			for (section in emptySections(source, lines)) out.push({
				file: file,
				span: new Span(section.from, section.to),
				rule: 'empty-doc-tag',
				severity: Severity.Warning,
				message: 'empty @${section.name} tag - it documents nothing'
			});
		}
	}

	/**
	 * Whether `tok` is a CLOSED doc comment with an interior - the only comment shape that
	 * can carry tags. Not `RefactorSupport.isDocBlock`: that one answers true for an
	 * UNCLOSED doc opener, which this rule must skip (its interior has no end to scan).
	 */
	private static function isDoc(source: String, tok: CommentTok): Bool {
		if (tok.isLine || source.substring(tok.from, tok.from + DOC_OPEN.length) != DOC_OPEN) return false;
		final from: Int = tok.from + DOC_OPEN.length;
		final to: Int = tok.to - DOC_CLOSE.length;
		return from <= to && source.substring(to, tok.to) == DOC_CLOSE;
	}

	/** The interior physical lines of a doc comment, each span excluding its newline. */
	private static function interiorLines(source: String, tok: CommentTok): Array<Span> {
		final from: Int = tok.from + DOC_OPEN.length;
		final to: Int = tok.to - DOC_CLOSE.length;
		final lines: Array<Span> = [];
		var start: Int = from;
		for (i in from ... to) if (StringTools.fastCodeAt(source, i) == '\n'.code) {
			lines.push(new Span(start, i));
			start = i + 1;
		}
		lines.push(new Span(start, to));
		return lines;
	}

	/**
	 * Every content-free tag section of one doc comment's interior, in source order. A
	 * section is the tag line plus the lines after it that open no tag; it counts as
	 * content-free only when the whitelisted tag carries no description AND every one of
	 * those continuation lines is whitespace and gutter stars.
	 */
	private static function emptySections(source: String, lines: Array<Span>): Array<TagSection> {
		final out: Array<TagSection> = [];
		var i: Int = 0;
		while (i < lines.length) {
			final bare: Int = bareFrom(source, lines[i]);
			final name: Null<String> = tagName(source, bare, lines[i].to);
			var last: Int = i;
			if (name != null) {
				final tag: String = name;
				while (last + 1 < lines.length && !opensTag(source, lines[last + 1])) last++;
				if (isEmptyTag(source, tag, bare + 1 + tag.length, lines[i].to) && blankLines(source, lines, i + 1, last)) out.push({
					name: tag,
					from: bare,
					to: lines[last].to,
					firstLine: i,
					lastLine: last
				});
			}
			i = last + 1;
		}
		return out;
	}

	/**
	 * Whether the tag is one of the whitelisted forms with no description: a `@param` with
	 * at most a name, or a bare `@return` / `@returns` / `@throws` / `@exception` / `@see`.
	 * Everything else carries information a signature does not and is kept.
	 */
	private static function isEmptyTag(source: String, name: String, from: Int, to: Int): Bool {
		final rest: String = StringTools.trim(source.substring(from, to));
		return switch name {
			case 'param': !hasSpace(rest);
			case 'return' | 'returns' | 'throws' | 'exception' | 'see': rest == '';
			case _: false;
		};
	}

	/**
	 * The whole-line deletion spans for the lines `marks` makes deletable: the interior's
	 * closing line keeps the delimiter's indentation, and every other line past the last
	 * surviving content joins the deletion so no gutter-only residue is stranded before the
	 * close. When the closer shares the last content line with a flagged tag, only that
	 * line's content is dropped - the closer stays put rather than being glued onto the line
	 * above.
	 */
	private static function deletionSpans(source: String, lines: Array<Span>, marks: Array<Bool>): Array<Span> {
		final mark: Array<Bool> = marks.copy();
		final last: Int = lines.length - 1;
		if (isGutterLine(source, lines[last])) mark[last] = false;
		var content: Int = last;
		while (content >= 0 && (mark[content] || isGutterLine(source, lines[content]))) content--;
		for (i in content + 1...last) mark[i] = true;
		final spans: Array<Span> = [];
		var i: Int = 0;
		while (i < lines.length) if (mark[i]) {
			var j: Int = i;
			while (j + 1 < lines.length && mark[j + 1]) j++;
			// A marked last line is never gutter-only: the reset above clears that case and the fill excludes `last`.
			if (j == last) {
				if (j > i) spans.push(lineRunSpan(source, lines, i, j - 1));
				spans.push(new Span(contentFrom(source, lines[j]), lines[j].to));
			} else
				spans.push(lineRunSpan(source, lines, i, j));
			i = j + 1;
		} else
			i++;
		return spans;
	}

	/** Whether every interior line the deletions would leave behind is a deletable gutter line. */
	private static function survivorsBlank(source: String, lines: Array<Span>, mark: Array<Bool>): Bool {
		for (i in 0...lines.length) if (!mark[i] && !isGutterLine(source, lines[i])) return false;
		return true;
	}

	/** Whether every line of the inclusive range `from...to` is content-free; vacuously true when it is empty. */
	private static function blankLines(source: String, lines: Array<Span>, from: Int, to: Int): Bool {
		for (i in from ... to + 1) if (!isBlankLine(source, lines[i])) return false;
		return true;
	}

	/** Whether the line holds nothing but whitespace and gutter stars. */
	private static function isBlankLine(source: String, line: Span): Bool {
		for (i in line.from ... line.to) {
			final c: Int = StringTools.fastCodeAt(source, i);
			if (!RefactorSupport.isSpace(c) && c != '*'.code) return false;
		}
		return true;
	}

	/** Whether the line's bare content opens a tag. */
	private static inline function opensTag(source: String, line: Span): Bool {
		return tagName(source, bareFrom(source, line), line.to) != null;
	}

	/**
	 * The tag name - the letters after an opening `@`, terminated by whitespace or the line
	 * end - or null when the bare content opens no tag. The terminator is what keeps
	 * `@param2` from reading as `@param` with a `2` argument.
	 */
	private static function tagName(source: String, bare: Int, to: Int): Null<String> {
		if (bare >= to || StringTools.fastCodeAt(source, bare) != '@'.code) return null;
		var i: Int = bare + 1;
		while (i < to && isLetter(StringTools.fastCodeAt(source, i))) i++;
		final terminated: Bool = i >= to || RefactorSupport.isSpace(StringTools.fastCodeAt(source, i));
		return i > bare + 1 && terminated ? source.substring(bare + 1, i) : null;
	}

	/** The offset of a line's bare content: past its leading whitespace, gutter star run, and the whitespace after it. */
	private static function bareFrom(source: String, line: Span): Int {
		var i: Int = line.from;
		while (i < line.to && RefactorSupport.isSpace(StringTools.fastCodeAt(source, i))) i++;
		while (i < line.to && StringTools.fastCodeAt(source, i) == '*'.code) i++;
		while (i < line.to && RefactorSupport.isSpace(StringTools.fastCodeAt(source, i))) i++;
		return i;
	}

	/** Whether `text` holds whitespace - i.e. more than one whitespace-delimited token. */
	private static function hasSpace(text: String): Bool {
		for (i in 0...text.length) if (RefactorSupport.isSpace(StringTools.fastCodeAt(text, i))) return true;
		return false;
	}

	/** Whether code unit `c` is an ASCII letter. */
	private static inline function isLetter(c: Int): Bool {
		return c >= 'a'.code && c <= 'z'.code || c >= 'A'.code && c <= 'Z'.code;
	}

	/**
	 * Whether the line is a DELETABLE gutter line: empty, or a single gutter star and
	 * nothing else. Stricter than `isBlankLine` on purpose - a run of two or more stars is
	 * a deliberate divider, i.e. content the fix must never swallow even when the section
	 * it sits in reads as content-free on the detection side.
	 */
	private static function isGutterLine(source: String, line: Span): Bool {
		var i: Int = line.from;
		while (i < line.to && RefactorSupport.isSpace(StringTools.fastCodeAt(source, i))) i++;
		if (i < line.to && StringTools.fastCodeAt(source, i) == '*'.code) i++;
		while (i < line.to && RefactorSupport.isSpace(StringTools.fastCodeAt(source, i))) i++;
		return i == line.to;
	}

	/**
	 * The interior lines the flagged sections make deletable: each tag line plus the
	 * continuation lines after it, taken only while they stay gutter-only. A divider ends
	 * the run, so it and everything past it in that section survive.
	 */
	private static function deletableLines(source: String, lines: Array<Span>, doomed: Array<TagSection>): Array<Bool> {
		final mark: Array<Bool> = [for (line in lines) false];
		for (section in doomed) {
			var last: Int = section.firstLine;
			while (last + 1 <= section.lastLine && isGutterLine(source, lines[last + 1])) last++;
			for (i in section.firstLine ... last + 1) mark[i] = true;
		}
		return mark;
	}

	/**
	 * The whole-physical-line span of the interior line run `from...to`. The run swallows
	 * the newline that PRECEDES it so no blank residue is left; the first interior line has
	 * none (the opener sits on it), and there the run stops short of a `\r` so a CRLF
	 * comment never degrades to a bare newline.
	 */
	private static function lineRunSpan(source: String, lines: Array<Span>, from: Int, to: Int): Span {
		if (from > 0) return new Span(lines[from].from - 1, lines[to].to);
		final start: Int = lines[0].from;
		final end: Int = lines[to].to;
		return new Span(start, end > start && StringTools.fastCodeAt(source, end - 1) == '\r'.code ? end - 1 : end);
	}

	/** The offset of the line's first non-space byte - its gutter star when it carries one. */
	private static function contentFrom(source: String, line: Span): Int {
		var i: Int = line.from;
		while (i < line.to && RefactorSupport.isSpace(StringTools.fastCodeAt(source, i))) i++;
		return i;
	}

}

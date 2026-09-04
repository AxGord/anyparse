package anyparse.query;

import anyparse.check.CheckScan;
import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.GrammarPlugin.LayoutMetrics;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;

/**
 * One physical line of a text that lies in a comment and renders wider than the configured width:
 * its verbatim text and its width in rendered columns. The width gate compares two LISTS of these
 * rather than two counts, because the decision and the line it names are different questions — the
 * count and the widest decide, and the multiset difference by text decides which line to quote.
 */
private typedef WideLine = {
	var text: String;
	var cols: Int;
}

/**
 * Text search-and-replace scoped to COMMENT bodies — the write-twin of `lit`
 * (which finds text in comments), as `rewrite` is the write-twin of `search`.
 * `rewrite` only reaches AST nodes; comments are trivia and never appear in the
 * parse tree, so neither `rewrite` nor `set-comment` (one block, whole-text)
 * can do a bulk find/replace across comments. This fills that gap.
 *
 * Every comment body (located by `RefactorSupport.collectCommentTokens`, which
 * skips string literals) is searched: in literal mode `find` is a substring and
 * `replace` is verbatim; in `regex` mode `find` is an `EReg` and `replace` is a
 * template where `${0}` / `${1}` / `${N}` expand to capture group N,
 * `${N+K}` / `${N-K}` shift group N (an integer) by K, and `$$` is a literal
 * `$`. Only comment bodies change — code and the comment delimiters are never touched.
 *
 * A replacement carrying a real NEWLINE is re-prefixed with the comment's own continuation
 * (`RefactorSupport.commentContinuation`) before it is spliced, in both modes: the writer
 * re-emits a comment interior byte for byte, so an unguttered line spliced into a doc block
 * is a corruption `fmt --list` calls canonical and every node-based rule is blind to. A
 * replacement line that already carries a gutter is not doubled — see
 * `RefactorSupport.ungutter`, which is also how a caller-supplied gutter is kept out of
 * `set-doc`. The result is canonical + re-parse-validated via
 * `RefactorSupport.canonicalize` (canonical-gated unless `reformat`), so a
 * replacement that would break the parse is rejected.
 *
 * The source is never mutated; the caller decides whether to write the result.
 */
@:nullSafety(Strict)
final class CommentRewrite {

	/**
	 * Rewrite text inside every comment of `source`. Returns `Ok(rewritten)`
	 * (unchanged when nothing matched) or an `Err` describing the failure (the
	 * source does not parse, an empty / bad pattern, or a result that does not
	 * parse).
	 */
	public static function rewrite(
		source: String, find: String, replace: String, regex: Bool, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String,
		?allowWide: Bool
	): EditResult {
		if (find.length == 0) return Err('find pattern is empty');

		try
			plugin.parseFile(source)
		catch (exception: ParseError)
			return Err('source does not parse: $exception')
		catch (exception: Exception)
			return Err('source does not parse: ${exception.message}');

		var ereg: Null<EReg> = null;
		if (regex) {
			try
				ereg = new EReg(find, 'g')
			catch (exception: Exception)
				return Err('invalid regex: ${exception.message}');
		}
		final compiled: Null<EReg> = ereg;

		final edits: Array<{ span: Span, text: String }> = [];
		try {
			for (tok in SourceComments.collectCommentTokens(plugin.lexicalRegions(source))) {
				final bodySpan: Span = SourceComments.commentBody(source, tok);
				final body: String = source.substring(bodySpan.from, bodySpan.to);
				// The splice is RAW and the writer re-emits a comment interior byte for byte, so a
				// replacement carrying a real newline would start a line with no continuation prefix
				// — the corruption `doc-comment-continuation` exists to see. Give every new line the
				// prefix THIS comment already uses instead.
				final continuation: String = SourceComments.commentContinuation(source, tok);
				final next: String = compiled != null
					? compiled.map(body, m -> SourceComments.reflowIntoComment(expandGroups(replace, m), continuation))
					: literalReplace(body, find, SourceComments.reflowIntoComment(replace, continuation));
				if (next == body) continue;
				// A ONE-LINE doc block that has just grown has to be re-opened, or its closer rides the last
				// content line and the writer eats the space before that line's star (`\t* text */`).
				final grown: Bool = next.indexOf('\n') >= 0 && isOneLineDocBlock(source, tok);
				edits.push({ span: bodySpan, text: grown ? SourceComments.openGrownDocBlock(next, continuation) : next });
			}
		} catch (exception: Exception)
			return Err(exception.message);

		if (edits.length == 0) return Ok(source);
		final result: EditResult = CanonicalEdit.canonicalize(source, edits, reformat, plugin, optsJson);
		if (allowWide == true) return result;
		return switch result {
			case Ok(text, _):
				final wide: Null<String> = gainedWideCommentLine(source, text, reformat, plugin, optsJson);
				wide == null ? result : Err(wide);
			case Err(_): result;
		};
	}

	private static inline function isDigit(c: Int): Bool {
		return c >= '0'.code && c <= '9'.code;
	}

	/**
	 * Whether `tok` is a doc block holding no line break — the shape whose closer would ride the last
	 * content line once the replacement grows past one line.
	 *
	 * WHERE the block starts is deliberately NOT asked. A first draft required it to start its own
	 * line, on the reasoning that the shape is a doc above a declaration; the closer rides the last
	 * content line wherever the block sits, and a trailing `class C {} /** One liner. *\/` grown to
	 * two lines came back from the writer as `* Second line. *\/` with the space before its star
	 * eaten — byte for byte the corruption this re-open exists to prevent. The writer moves the
	 * comment onto its own line during the same edit anyway, so the position the guard read no longer
	 * held by the time the damage landed.
	 */
	private static function isOneLineDocBlock(source: String, tok: { from: Int, to: Int, isLine: Bool }): Bool {
		return !tok.isLine && tok.from + 2 < source.length && source.fastCodeAt(tok.from + 2) == '*'.code
			&& source.substring(tok.from, tok.to).indexOf('\n') < 0;
	}

	/**
	 * The first comment line the edit pushed past the configured width, as the refusal to print, or
	 * null when it pushed none.
	 *
	 * WIDTH was the last unguarded half of this op. The writer re-emits a comment interior byte for
	 * byte, so an over-long one-line replacement leaves a doc line nothing in this project measures:
	 * `fmt --list` is clean because the file IS what the writer emits, and no rule reads a comment
	 * line's width. It bit two slices of this campaign, and both times a human reading the diff was
	 * the only gate.
	 *
	 * A block that was ALREADY over-width keeps its own style — that is the caller's file, not this
	 * op's to police; only a line the edit ADDED to that set is refused, and `--allow-wide` waives it.
	 *
	 * Two questions, not one. WHETHER to refuse is the aggregate — the count of over-width comment
	 * lines and the widest of them, against the same file canonicalised but unedited. WHICH line to
	 * name is the multiset difference by line text, so the message can never quote a line the edit
	 * left byte-identical.
	 */
	private static function gainedWideCommentLine(
		source: String, after: String, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): Null<String> {
		final metrics: Null<LayoutMetrics> = plugin.layoutMetrics(optsJson);
		if (metrics == null) return null;
		final width: Int = metrics.lineWidth;
		final tab: Int = metrics.indentWidth;
		final got: Array<WideLine> = wideCommentLines(after, width, tab, plugin.lexicalRegions(after));
		if (got.length == 0) return null;
		// The baseline is the source CANONICALISED but UNEDITED, not the raw source. Under
		// `--reformat` — the flag's whole use case being a file that is not canonical — the writer
		// re-indents everything, so a comment the command never mentioned can cross the width on its
		// own, and against the raw source that reads as this edit's doing. Measured: a 135-column
		// `//` at column 0 that the writer moves to three tabs refused an edit to a different line.
		final base: String = switch CanonicalEdit.canonicalize(source, [], reformat, plugin, optsJson) {
			case Ok(text, _): text;
			case Err(_): source;
		};
		final had: Array<WideLine> = wideCommentLines(base, width, tab, plugin.lexicalRegions(base));
		// COUNT and WIDEST, not line identity. Keying on the line's TEXT made every edit that touches
		// an over-width line read as a new one — the text necessarily changed — so `comment-rewrite`
		// refused a rename that SHORTENED a 155-column line to 154, in exactly the case this
		// function's own doc promised to allow.
		if (got.length <= had.length && widestOf(got) <= widestOf(had)) return null;
		// The DECISION is that aggregate; the LINE NAMED is not. Reporting the file's widest
		// over-width comment line quoted a line the replacement never touched whenever the file
		// already held a wider one — measured on this tree's own `LoopGuard.hx`, where an edit that
		// joined two doc lines into one of 173 columns was refused with "at 279 columns" over a
		// typedef doc 320 lines away. Blame the widest line the edit ADDED to the set instead.
		final blamed: WideLine = gainedLine(got, had);
		return 'the replacement leaves a comment line at ${blamed.cols} columns, past the configured $width'
			+ ' — supply the line breaks yourself (with the prefix that position needs), or pass --allow-wide:\n${blamed.text}';
	}

	/** The widest of `lines` in rendered columns, 0 when there is none. */
	private static function widestOf(lines: Array<WideLine>): Int {
		return lines.length == 0 ? 0 : widestLine(lines).cols;
	}

	/** The widest of a NON-EMPTY `lines`. */
	private static function widestLine(lines: Array<WideLine>): WideLine {
		var best: WideLine = lines[0];
		for (line in lines) if (line.cols > best.cols) best = line;
		return best;
	}

	/**
	 * The widest over-width comment line the edit is answerable for: `got` minus `had` as a MULTISET
	 * keyed by line text, so a line the edit left byte-identical is matched off against its own
	 * counterpart in the baseline and never blamed. A line whose text changed is by construction one
	 * the edit touched.
	 *
	 * The remainder cannot be empty when the caller refuses — a higher count leaves an unmatched
	 * line, and a wider widest is a text no baseline line can carry at that width — but the fallback
	 * is the file's widest rather than a throw: this runs on the refusal path, where the worst a
	 * wrong line costs is a misleading message, and the worst a throw costs is the refusal itself.
	 */
	private static function gainedLine(got: Array<WideLine>, had: Array<WideLine>): WideLine {
		final unmatched: Array<String> = [for (line in had) line.text];
		var blamed: Null<WideLine> = null;
		for (line in got) {
			final at: Int = unmatched.indexOf(line.text);
			if (at >= 0) {
				unmatched.splice(at, 1);
				continue;
			}
			if (blamed == null || line.cols > blamed.cols) blamed = line;
		}
		return blamed ?? widestLine(got);
	}

	/**
	 * Every distinct physical line of `text` that lies in a comment and renders wider than `width`, in
	 * document order. Two comments on ONE line yield it once.
	 */
	private static function wideCommentLines(text: String, width: Int, tab: Int, regions: Array<LexRegion>): Array<WideLine> {
		final seen: Array<Int> = [];
		final lines: Array<WideLine> = [];
		for (tok in SourceComments.collectCommentTokens(regions)) {
			var from: Int = text.lastIndexOf('\n', tok.from) + 1;
			while (from < tok.to) {
				var to: Int = text.indexOf('\n', from);
				if (to < 0) to = text.length;
				// A trailing `\r` is not ink; `CheckScan.displayColumn` is the project's one answer to
				// what a tab is worth, and it is the WRITER's (a flat `indentWidth`, not a tab stop).
				final end: Int = to > from && text.fastCodeAt(to - 1) == '\r'.code ? to - 1 : to;
				final cols: Int = CheckScan.displayColumn(text, from, end, tab);
				if (cols > width && !seen.contains(from)) {
					seen.push(from);
					lines.push({ text: text.substring(from, end), cols: cols });
				}
				from = to + 1;
			}
		}
		return lines;
	}

	/**
	 * Expand a `regex`-mode replacement template against the active match `m`:
	 * `$$` becomes `$`; `$<digits>` / `${<digits>}` a capture group; `${N+K}` /
	 * `${N-K}` group N (an integer) shifted by K. Throws on a group the pattern
	 * does not capture, a non-integer group under a shift, or a malformed
	 * brace spec — the caller turns the throw into an `Err`.
	 */
	private static function expandGroups(template: String, m: EReg): String {
		final buf: StringBuf = new StringBuf();
		final n: Int = template.length;
		var i: Int = 0;
		while (i < n) {
			final c: Int = template.fastCodeAt(i);
			if (c != '$'.code) {
				buf.addChar(c);
				i++;
				continue;
			}
			if (i + 1 < n && template.fastCodeAt(i + 1) == '$'.code) {
				buf.addChar('$'.code);
				i += 2;
				continue;
			}
			if (i + 1 < n && template.fastCodeAt(i + 1) == '{'.code) {
				final close: Int = template.indexOf('}', i + 2);
				if (close < 0) throw new Exception('unterminated brace in replacement template');
				buf.add(expandSpec(template.substring(i + 2, close), m));
				i = close + 1;
				continue;
			}
			var j: Int = i + 1;
			while (j < n && isDigit(template.fastCodeAt(j))) j++;
			if (j == i + 1) {
				buf.addChar('$'.code);
				i++;
				continue;
			}
			buf.add(groupValue(Std.parseInt(template.substring(i + 1, j)), m));
			i = j;
		}
		return buf.toString();
	}

	/** `N` (group source) or `N+K` / `N-K` (integer group N shifted by K). */
	private static function expandSpec(spec: String, m: EReg): String {
		final plus: Int = spec.indexOf('+');
		final minus: Int = spec.indexOf('-');
		final opAt: Int = plus >= 0 ? plus : minus;
		if (opAt <= 0) return groupValue(Std.parseInt(spec), m);
		final num: Null<Int> = Std.parseInt(spec.substring(opAt + 1));
		if (num == null) throw new Exception('bad shift in template spec "$spec"');
		final shift: Int = plus >= 0 ? num : -num;
		final raw: String = groupValue(Std.parseInt(spec.substring(0, opAt)), m);
		final value: Null<Int> = Std.parseInt(raw.trim());
		if (value == null) throw new Exception('template group is not an integer: "$raw"');
		return '${value + shift}';
	}

	/**
	 * Source of capture group `idx` for the active match; empty for an
	 * unmatched optional group. Throws when the spec is not a number or the
	 * pattern has no such group.
	 */
	private static function groupValue(idx: Null<Int>, m: EReg): String {
		if (idx == null) throw new Exception('bad group reference in replacement template');
		final index: Int = idx;
		var matched: Null<String>;
		try
			matched = m.matched(index)
		catch (exception: Exception)
			throw new Exception('replacement references group $index which the pattern does not capture');
		return matched ?? '';
	}

	/**
	 * Literal find/replace inside a comment body, matching ACROSS the body's line
	 * continuations: the body is normalized (each `\n` + ` * ` doc prefix folded to
	 * one space) for the search, and every non-overlapping match is projected back
	 * to its span in the original body via the index map — so a phrase wrapped over
	 * two ` * ` lines is found and replaced. Consuming the continuation between the two lines is safe because the replacement is
	 * re-prefixed before it is spliced (`RefactorSupport.reflowIntoComment`) — the writer does
	 * NOT re-wrap a comment interior, it re-emits it byte for byte, which is what made the raw
	 * splice a corruption no gate could see.
	 *
	 * `find` is normalised the SAME way, which is what makes a multi-line FIND work.
	 * Without that, a find carrying a newline could never match anything in either
	 * spelling: written with the ` * ` prefixes it did not match the prefix-free
	 * normalised body, and written without them it did not match either, because the
	 * body's own break is one SPACE there. The tool then reported "rewrote 0 file(s)",
	 * which is indistinguishable from a find that is genuinely absent — the CLI now
	 * says so in as many words.
	 */
	private static function literalReplace(body: String, find: String, replace: String): String {
		final normalized: { text: String, map: Array<Int> } = SourceComments.normalizeCommentBody(body);
		final norm: String = normalized.text;
		final map: Array<Int> = normalized.map;
		final needle: String = SourceComments.normalizeCommentBody(find).text;
		if (needle.length == 0) return body;
		final buf: StringBuf = new StringBuf();
		var cursor: Int = 0;
		var hit: Int = norm.indexOf(needle, 0);
		while (hit >= 0) {
			buf.add(body.substring(cursor, map[hit]));
			buf.add(replace);
			cursor = map[hit + needle.length];
			hit = norm.indexOf(needle, hit + needle.length);
		}
		buf.add(body.substring(cursor));
		return buf.toString();
	}

}

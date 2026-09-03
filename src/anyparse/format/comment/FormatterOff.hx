package anyparse.format.comment;

using StringTools;

/**
 * `// @formatter:off` … `// @formatter:on` — the author's opt-out from
 * formatting, restored over the writer's output.
 *
 * A layout the writer cannot derive — a colour table packed to a grid, a
 * matrix of coordinates, a switch aligned by hand — has no rule that
 * reproduces it, only a rule that happens not to break it. Encoding such a
 * layout as a config threshold is how `arrayWrap: itemCount >= 20` was born
 * in a consumer project: it fit ONE declaration and silently reflowed three
 * others whose hand layout the author had already marked here.
 *
 * The marker is exact — a line comment whose text is `// @formatter:off`,
 * nothing before it but whitespace or code, nothing after it. `//@formatter:off`
 * with no gap is not a marker, and neither is the string `'// @formatter:off'`;
 * both are the fork's behaviour (`CodeLines.skipFormatterOff`), which this
 * mirrors so the corpus stays a valid oracle.
 *
 * Region = from the line carrying `off` through the line carrying `on`,
 * both inclusive, copied byte-for-byte from the source. Without a closing
 * `on` the region runs to the end of the file. A second `off` inside a
 * region is ordinary text; an `on` with no open region is ignored.
 *
 * ## Why a post-pass and not a Doc
 *
 * The region is a range of LINES, orthogonal to the tree: it can open inside
 * a switch and close inside an array literal. The Doc IR has no node for
 * "these bytes", and giving it one would mean suppressing every Doc whose
 * span falls in the range — the whole writer would have to learn about it.
 * The fork solves it the same way, one stage lower: `CodeLines.buildLines`
 * bypasses line assembly for the region and pushes a `VerbatimCodeLine`.
 *
 * ## Refusal
 *
 * Splicing by line index assumes the markers still delimit the same code
 * after formatting. Two checks defend that, and either failing returns the
 * writer's output UNTOUCHED rather than a mis-spliced file: the region
 * counts must match between source and output, and the code preceding a
 * marker on its own line must match too. The second catches the case that
 * would actually lose bytes — a statement on the line above the marker
 * glued onto it, which the verbatim copy would then overwrite.
 */
@:nullSafety(Strict)
final class FormatterOff {

	private static inline final OFF: String = '// @formatter:off';
	private static inline final ON: String = '// @formatter:on';

	/**
	 * `written` with every `@formatter:off` region replaced by the bytes it
	 * covers in `source`; `written` unchanged when the source declares no
	 * region, or when the two texts disagree about where the regions are.
	 *
	 * `scan` is the caller's grammar comment lexer: the marker is a LINE
	 * COMMENT, and which bytes are one is the grammar's answer, not this
	 * package's — the same seam `CommentInventory` takes.
	 */
	public static function restore(source: String, written: String, scan: CommentScan): String {
		final srcRegions: Array<Region> = regionsOf(source, scan);
		if (srcRegions.length == 0) return written;
		final outRegions: Array<Region> = regionsOf(written, scan);
		if (outRegions.length != srcRegions.length) return written;

		final srcLines: Array<String> = source.split('\n');
		final outLines: Array<String> = written.split('\n');
		final result: Array<String> = [];
		var cursor: Int = 0;
		for (k => out in outRegions) {
			final src: Region = srcRegions[k];
			if (out.from < cursor || out.to >= outLines.length || src.to >= srcLines.length) return written;
			if (out.headCode != src.headCode || out.tailCode != src.tailCode) return written;
			while (cursor < out.from) {
				result.push(outLines[cursor]);
				cursor++;
			}
			for (line in src.from ... src.to + 1) result.push(srcLines[line]);
			// The fork trims the copied block's tail unless it runs to the
			// file's end, where the trailing whitespace is the file's own.
			if (src.to < srcLines.length - 1) result[result.length - 1] = StringTools.rtrim(result[result.length - 1]);
			cursor = out.to + 1;
		}
		while (cursor < outLines.length) {
			result.push(outLines[cursor]);
			cursor++;
		}
		return result.join('\n');
	}

	/** Every `off`…`on` region of `text`, in source order, as line indices. */
	private static function regionsOf(text: String, scan: CommentScan): Array<Region> {
		final marks: Array<Mark> = [];
		scan(text, (start: Int, end: Int) -> {
			final body: String = text.substring(start, end);
			if (body == OFF || body == ON) marks.push({
				offset: start,
				opens: body == OFF,
				line: 0,
				code: ''
			});
		});
		final out: Array<Region> = [];
		if (marks.length == 0) return out;
		locate(text, marks);
		final lastLine: Int = countLines(text) - 1;

		var i: Int = 0;
		while (i < marks.length) {
			// An `on` with no region open is not a marker at all.
			if (!marks[i].opens) {
				i++;
				continue;
			}
			// A second `off` inside the region is ordinary text — scan past
			// every one of them to the `on` that actually closes it.
			var j: Int = i + 1;
			while (j < marks.length && marks[j].opens) j++;
			if (j >= marks.length) {
				out.push({
					from: marks[i].line,
					to: lastLine,
					headCode: marks[i].code,
					tailCode: null
				});
				break;
			}
			out.push({
				from: marks[i].line,
				to: marks[j].line,
				headCode: marks[i].code,
				tailCode: marks[j].code
			});
			i = j + 1;
		}
		return out;
	}

	/**
	 * Fills each mark's line index and the code preceding it on that line.
	 * One forward walk — the marks arrive in offset order.
	 */
	private static function locate(text: String, marks: Array<Mark>): Void {
		var line: Int = 0;
		var lineStart: Int = 0;
		var pos: Int = 0;
		for (mark in marks) {
			while (pos < mark.offset) {
				if (text.fastCodeAt(pos) == '\n'.code) {
					line++;
					lineStart = pos + 1;
				}
				pos++;
			}
			mark.line = line;
			mark.code = text.substring(lineStart, mark.offset).trim();
		}
	}

	private static function countLines(text: String): Int {
		var lines: Int = 1;
		for (i in 0...text.length) if (text.fastCodeAt(i) == '\n'.code) lines++;
		return lines;
	}

}

/** One `@formatter:off`/`:on` comment: where it sits and what shares its line. */
private typedef Mark = {
	final offset: Int;
	final opens: Bool;
	var line: Int;
	var code: String;
}

/**
 * A verbatim region as inclusive line indices, carrying the code that
 * precedes each marker on its own line — the anchor the splice verifies
 * before trusting the indices.
 */
private typedef Region = {
	final from: Int;
	final to: Int;
	final headCode: String;
	final tailCode: Null<String>;
}

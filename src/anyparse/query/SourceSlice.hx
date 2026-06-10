package anyparse.query;

import anyparse.runtime.Span;

using StringTools;

/**
 * Parser-agnostic source-slice helpers for the `--source` / `--doc`
 * render-layer opt-ins.
 *
 * Deliberately depends only on the raw source string and a `Span`
 * (offset pair) — never on `QueryNode` or any parse tree. This mirrors
 * the `parseFileTypeRefs` separate-projection discipline at the slice
 * layer: `ast` / `refs` / `uses` / `meta` default output is untouched;
 * the doc / source text is reconstructed from offsets only when a flag
 * asks for it.
 *
 * `slice` is the verbatim span cut. `leadingDoc` walks backward over
 * blank and single-line `@…` annotation lines (a decl's recorded
 * `span.from` sits at the `class` / `var` / `function` keyword, after
 * any leading metadata, which the span parser surfaces as separate
 * sibling nodes) to the immediately-preceding block-style or
 * line-style comment. Multi-line paren-continued metadata is a
 * documented v1 limitation — anyparse grammar decls use single-line
 * metas.
 */
@:nullSafety(Strict)
final class SourceSlice {

	/** Verbatim source between `span.from` and `span.to`, clamped. */
	public static function slice(source: String, span: Null<Span>): String {
		if (span == null) return '';
		final from: Int = span.from < 0 ? 0 : span.from;
		final to: Int = span.to > source.length ? source.length : span.to;
		if (from >= to) return '';
		return source.substring(from, to);
	}

	/**
	 * Verbatim leading doc-comment block for the declaration whose
	 * `span.from` is given, or `null` when none is adjacent. Indentation
	 * of the original source is preserved.
	 */
	public static function leadingDoc(source: String, span: Null<Span>): Null<String> {
		if (span == null) return null;
		final lineStart: Array<Int> = [];
		final lineEnd: Array<Int> = [];
		computeLines(source, lineStart, lineEnd);
		if (lineStart.length == 0) return null;

		final from: Int = span.from < 0 ? 0 : (span.from > source.length ? source.length : span.from);
		final declLine: Int = lineOfOffset(lineStart, lineEnd, from);

		var i: Int = declLine - 1;
		while (i >= 0) {
			final trimmed: String = source.substring(lineStart[i], lineEnd[i]).trim();
			if (trimmed.length == 0 || trimmed.startsWith('@')) {
				i--;
				continue;
			}
			break;
		}
		if (i < 0) return null;

		final endLineTrim: String = source.substring(lineStart[i], lineEnd[i]).trim();
		if (endLineTrim.endsWith('*/')) {
			var j: Int = i;
			while (j >= 0 && source.substring(lineStart[j], lineEnd[j]).indexOf('/*') < 0) j--;
			if (j < 0) return null;
			return source.substring(lineStart[j], lineEnd[i]);
		}
		if (endLineTrim.startsWith('//')) {
			var k: Int = i;
			while (k - 1 >= 0 && source.substring(lineStart[k - 1], lineEnd[k - 1]).trim().startsWith('//')) k--;
			return source.substring(lineStart[k], lineEnd[i]);
		}
		return null;
	}

	/**
	 * Populate `starts` / `ends` with the offset range of every line.
	 * `ends[n]` excludes the newline; a trailing `\r` stays in range so
	 * the verbatim slice is byte-faithful while `StringTools.trim`
	 * comparisons ignore it.
	 */
	private static function computeLines(source: String, starts: Array<Int>, ends: Array<Int>): Void {
		var lineStart: Int = 0;
		for (idx in 0...source.length) if (StringTools.fastCodeAt(source, idx) == '\n'.code) {
			starts.push(lineStart);
			ends.push(idx);
			lineStart = idx + 1;
		}
		starts.push(lineStart);
		ends.push(source.length);
	}

	/** Index of the line whose range contains `offset`. */
	private static function lineOfOffset(starts: Array<Int>, ends: Array<Int>, offset: Int): Int {
		for (n in 0...starts.length) if (offset <= ends[n]) return n;
		return starts.length - 1;
	}

}

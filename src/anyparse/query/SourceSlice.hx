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
 * layer: `ast` / `refs` / `uses` default output is untouched; the doc /
 * source text is reconstructed from offsets only when a flag asks for it.
 *
 * WHICH span it is handed is therefore the CALLER's decision, and the two
 * callers deliberately answer differently. `ast --select` / `ast --at`
 * hand the DECLARATION-GROUP window — `RefactorSupport.declGroupSpan`
 * then `trailingTrimmedSpan`, `Patch`'s own order — because `--select`
 * and `--at` are the address grammar `patch` and `replace-node` take, so
 * the text a user copies out of `ast --source` has to be the text those
 * ops overwrite; cutting the bare node span instead handed back a
 * declaration without its `@:keep` / `public` / `#if … enum #end` and
 * `replace-node` dropped them at rc 0, and `--doc --source` together
 * printed the run between the two blocks in neither. `refs` / `uses` `--source` hand the HIT's own span: a hit is an
 * occurrence in a multi-file listing rather than a node the caller
 * addressed, its record carries no tree to fold against, and for every
 * non-declaration hit the fold would be a no-op anyway. A caller that
 * wants op-ready text reads it with `source --select` or
 * `ast --select --source`.
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
		return from >= to ? '' : source.substring(from, to);
	}

	/**
	 * Verbatim leading doc-comment block for the declaration whose `span.from` is given, or
	 * `null` when none is adjacent. Indentation of the original source is preserved. The
	 * comment's extent comes from `RefactorSupport.commentBlockAt` (the lexer's tokens), so an
	 * opener sequence inside the doc's own text is content rather than a false start, and a
	 * run of full-line line comments is returned as one block.
	 */
	public static function leadingDoc(source: String, span: Null<Span>): Null<String> {
		if (span == null) return null;
		final lineStart: Array<Int> = [];
		final lineEnd: Array<Int> = [];
		computeLines(source, lineStart, lineEnd);
		if (lineStart.length == 0) return null;

		final from: Int = if (span.from < 0)
			0
		else if (span.from > source.length)
			source.length
		else
			span.from;
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
		if (!endLineTrim.endsWith('*/') && !endLineTrim.startsWith('//')) return null;
		// Ask the lexer where the comment BEGINS instead of scanning lines for an opener:
		// a `/*` written inside the doc's own text is content, not a boundary. The same
		// call merges a contiguous run of full-line line comments into one block, which
		// is what the hand-rolled `//` walk did.
		var cursor: Int = lineEnd[i] - 1;
		while (cursor > lineStart[i] && isBlank(source.fastCodeAt(cursor))) cursor--;
		final block: Null<Span> = RefactorSupport.commentBlockAt(source, cursor);
		// A comment that does not START its line trails the CODE before it — the line
		// `var keep:Int; /* about keep */` ends in `*/` like any doc line, so the line
		// scan above accepts it and the slice would hand back the previous
		// declaration's code as this one's documentation. Same rule the deletion span
		// uses (`RefactorSupport.startsItsLine`), so the read and the write side agree
		// on which comment belongs to whom.
		return block == null || !RefactorSupport.startsItsLine(source, block.from)
			? null
			: source.substring(lineStart[lineOfOffset(lineStart, lineEnd, block.from)], lineEnd[i]);
	}

	/** Whether `code` is a space, tab or carriage return — the trailing bytes a line may carry past its last real character. */
	private static inline function isBlank(code: Int): Bool {
		return code == ' '.code || code == '\t'.code || code == '\r'.code;
	}

	/**
	 * Populate `starts` / `ends` with the offset range of every line.
	 * `ends[n]` excludes the newline; a trailing `\r` stays in range so
	 * the verbatim slice is byte-faithful while `StringTools.trim`
	 * comparisons ignore it.
	 */
	private static function computeLines(source: String, starts: Array<Int>, ends: Array<Int>): Void {
		var lineStart: Int = 0;
		for (idx in 0...source.length) if (source.fastCodeAt(idx) == '\n'.code) {
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

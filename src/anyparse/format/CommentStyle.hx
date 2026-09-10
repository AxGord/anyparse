package anyparse.format;

/**
 * Block-comment output style for multi-line `/*…*\/` comments: the default
 * `Verbatim` round-trips source content byte-identical, and the other values opt
 * into a writer-side canonicalization of wrap shape and per-line markers.
 *
 * Canonicalization reaches MULTI-LINE DOC comments only — content that opens
 * `/**` and carries a physical newline, judged on the source text rather than a
 * parsed line count. A plain `/* … *\/` block always takes the `Verbatim` path,
 * because rewriting it would mint a haxedoc where the author wrote none. The
 * pass owns the wrap and the marker column, not every interior byte: whitespace
 * past the block's common prefix is the author's own indentation and survives,
 * except on a line that carried a ` * ` gutter, where the leading whitespace is
 * the marker COLUMN and re-emits at the canonical one.
 *
 * Both DOC styles also collapse a block whose interior reduces to one content
 * line into `/** <content> *\/` when that line fits `lineWidth` at its emission
 * column; the collapse is one-way, so a doc already written on one line is never
 * expanded. `Plain` does not collapse — its one-line form is the demotion below.
 *
 * - `Verbatim` (default) — content, markers, blank lines and indent as written.
 * - `Plain` — `/*` … `*\/` with each interior line at `currentIndent +
 *   indentUnit + content`, source ` * ` markers stripped. DEMOTES a doc, since
 *   its only reachable input is a `/**` block and the result is no longer what
 *   the compiler and doc generators extract; no `hxformat.json` token selects
 *   it, and it remains only for a caller building `WriteOptions` by hand.
 * - `Javadoc` — `/**` … ` *\/` with a ` * ` marker column on every line.
 * - `JavadocNoStars` — doc delimiters with plain-indent content and no marker
 *   column, so the close is flush and a blank interior line emits nothing.
 */
enum abstract CommentStyle(Int) from Int to Int {

	var Verbatim = 0;
	var Plain = 1;
	var Javadoc = 2;
	var JavadocNoStars = 3;

}

package anyparse.format;

/**
 * Block-comment output style for multi-line `/*…*\/` comments.
 *
 * Default `Verbatim` preserves source content byte-identical between
 * `/*` and `*\/`. The other values opt into a writer-side
 * canonicalization pass that normalises wrap shape and per-line
 * markers to a fixed style — useful when a project wants every doc
 * block to look the same regardless of how it was originally
 * authored.
 *
 * - `Verbatim` (default) — source content round-trips byte-identical.
 *    `*` runs adjacent to wrap delimiters, ` * ` per-line markers, blank
 *    lines, indent — all preserved as the author wrote them. The writer
 *    emits `/*` + content + `*\/` verbatim.
 * - `Plain` — `/*` opening, `*\/` closing, each interior line at
 *    `currentIndent + indentUnit + content`. Strips any source ` * `
 *    markers and re-emits content with plain indent.
 * - `Javadoc` — `/**` opening, `**\/` closing, each interior line at
 *    `currentIndent + " * " + content`. Classic Haxe / Java doc-block
 *    appearance regardless of what the source used.
 * - `JavadocNoStars` — `/**` opening, `**\/` closing, each interior
 *    line at `currentIndent + indentUnit + content` (hybrid: doc-style
 *    delimiters with plain-indent content).
 */
enum abstract CommentStyle(Int) from Int to Int {
	var Verbatim = 0;
	var Plain = 1;
	var Javadoc = 2;
	var JavadocNoStars = 3;
}

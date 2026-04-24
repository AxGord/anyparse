package anyparse.format;

/**
 * Block-comment output style for multi-line `/*…*\/` comments.
 *
 * Captured `/*…*\/` content flows through `BlockCommentBodyParser`,
 * which strips leading whitespace and any `*` markers — source style
 * is not preserved. This enum drives how the writer re-wraps the
 * captured content at emit time.
 *
 * - `Plain` — `/*` opening, `*\/` closing, each interior line at
 *    `currentIndent + indentUnit + content`. Minimal wrap; no `*`
 *    markers on content lines.
 * - `Javadoc` — `/**` opening, `**\/` closing, each interior line at
 *    `currentIndent + " * " + content`. Classic Haxe / Java doc-block
 *    appearance regardless of what the source used.
 */
enum abstract CommentStyle(Int) from Int to Int {
	var Plain = 0;
	var Javadoc = 1;
}

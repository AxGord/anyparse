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
 * The canonical styles apply to MULTI-LINE DOC comments only: content
 * that opens `/**` AND carries a physical newline. "Multi-line" is
 * measured on the source text, not on a parsed line count — the block
 * parser elides the separator before a trailing `*\/`, so `/** doc\n*\/`
 * is one parsed line but two physical ones and does canonicalize. A
 * plain `/* … *\/` block takes the `Verbatim` path whatever this option
 * says: rewriting it would mint a haxedoc where the author wrote none.
 * A doc written on one physical line is not this option's concern —
 * the writer never routes a newline-free comment to the style pass at
 * all (`WriterCodegen.leadingCommentDocRun` returns first).
 *
 * The pass owns the wrap and the marker column, not every interior
 * byte: whitespace a line carries beyond the block's common prefix is
 * the author's own indentation and survives. A line that carried a
 * ` * ` gutter is the exception — its leading whitespace is the marker
 * COLUMN, not text depth, so it re-emits at the canonical column.
 *
 * The two DOC styles also COLLAPSE: a block whose interior reduces to
 * exactly one content line (empty edge lines dropped) re-emits as
 * `/** <content> *\/` when that line fits `lineWidth` at its actual
 * emission column, and keeps the multi-line shape when it does not.
 * One-way — a doc the author already wrote on one line is never
 * expanded, whatever its length. `Plain` does not collapse: its
 * one-line form is `/* … *\/`, the demotion described below.
 *
 * - `Verbatim` (default) — source content round-trips byte-identical.
 *    `*` runs adjacent to wrap delimiters, ` * ` per-line markers, blank
 *    lines, indent — all preserved as the author wrote them. The writer
 *    emits `/*` + content + `*\/` verbatim.
 * - `Plain` — `/*` opening, `*\/` closing, each interior line at
 *    `currentIndent + indentUnit + content`. Strips any source ` * `
 *    markers and re-emits content with plain indent. DEMOTES a doc: its
 *    only reachable input is a `/**` block, and re-wrapping that as
 *    `/*` removes it from what the compiler and every doc generator
 *    extract. For that reason no `hxformat.json` token selects it —
 *    `comments.blockCommentStyle: "plain"` falls through to `Verbatim`
 *    — and it remains only for a caller building `WriteOptions` by hand.
 * - `Javadoc` — `/**` opening, ` *\/` closing, each interior line at
 *    `currentIndent + " * " + content`. Classic Haxe / Java doc-block
 *    appearance regardless of what the source used; the close carries
 *    one pad space so its `*` sits in the marker column.
 * - `JavadocNoStars` — `/**` opening, `*\/` closing, each interior
 *    line at `currentIndent + indentUnit + content` (hybrid: doc-style
 *    delimiters with plain-indent content). No marker column, so the
 *    close is flush and a blank interior line emits nothing rather than
 *    a whitespace-only row.
 */
enum abstract CommentStyle(Int) from Int to Int {

	var Verbatim = 0;
	var Plain = 1;
	var Javadoc = 2;
	var JavadocNoStars = 3;

}

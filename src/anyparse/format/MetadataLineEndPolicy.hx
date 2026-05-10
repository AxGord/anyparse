package anyparse.format;

/**
 * Line-end policy for a metadata `@:tryparse` Star — controls
 * inter-element separator and the gap between the LAST metadata and
 * the next sibling field (modifier / member keyword).
 *
 * `None` (default) — source-driven separator from per-element
 * `newlineBefore` trivia; no forced gap after the last element.
 * Byte-identical to the pre-slice engine.
 *
 * `After` — every inter-element separator becomes a hardline AND a
 * hardline fires after the last element. Source layout is collapsed
 * to one-metadata-per-line regardless of how the metas were written.
 *
 * `AfterLast` — inter-element separator stays source-driven, but a
 * hardline ALWAYS fires after the last element. Preserves the
 * author's inline grouping (`@A @B`) while guaranteeing the final
 * metadata sits on its own line.
 *
 * `ForceAfterLast` — inter-element separator is forced to a single
 * space (collapses any source newlines between metas) AND a
 * hardline fires after the last element. Produces a canonical
 * `@A @B @C\nfunction main()` shape.
 *
 * Consumed by `@:fmt(metaLineEndPolicy('<optField>'))` on a
 * `@:trivia @:tryparse` Star — the writer reads `opt.<optField>`
 * per generated parser run.
 *
 * Format-neutral — lives in `anyparse.format` so grammars for other
 * languages that carry sequence-style annotations (decorators,
 * attributes) can reuse the same shape.
 */
enum abstract MetadataLineEndPolicy(Int) from Int to Int {

	final None = 0;

	final After = 1;

	final AfterLast = 2;

	final ForceAfterLast = 3;
}

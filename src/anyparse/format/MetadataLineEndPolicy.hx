package anyparse.format;

/**
 * Line-end policy for a metadata `@:tryparse` Star — controls
 * inter-element separator and the gap between the LAST metadata and
 * the next sibling field (modifier / member keyword).
 *
 * No policy reads the source layout: the output is a function of the
 * AST and the knob.
 *
 * `None` — every inter-element separator is a single space; no forced
 * gap after the last element.
 *
 * `After` — every inter-element separator becomes a hardline AND a
 * hardline fires after the last element: one metadata per line.
 *
 * `AfterLast` / `ForceAfterLast` — inter-element separator is a single
 * space AND a hardline fires after the last element: the
 * `@A @B @C\nfunction main()` shape.
 *
 * `Fit` — decided by width, from simplicity the grammar's predicate reads
 * off each element: one simple element stays on the declaration's line
 * when that line fits, several simple ones share one line of their own
 * above it when that row fits, and anything else is one per line.
 *
 * Consumed by `@:fmt(metaLineEndPolicy('<optField>'))` and its
 * `metaLineEndIfCtor` / `metaLineEndChain` refinements, which name a
 * metadata site's knob (`anyparse.macro.WriterMetaLineEndLowering`).
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
	final Fit = 4;
}

package anyparse.format;

/**
 * Line-end policy for a metadata `@:tryparse` Star — controls
 * inter-element separator and the gap between the LAST metadata and
 * the next sibling field (modifier / member keyword).
 *
 * Only `None` reads the source layout; every other policy's output is a
 * function of the AST and the knob.
 *
 * `None` — no break is added: an inter-element separator is a single
 * space unless the source breaks there, where one line break stays (a
 * blank does not), and the gap after the last element follows the source.
 *
 * `After` — every inter-element separator becomes a hardline AND a
 * hardline fires after the last element: one metadata per line.
 *
 * `AfterLast` / `ForceAfterLast` — inter-element separator is a single
 * space AND a hardline fires after the last element: the
 * `@A @B @C\nfunction main()` shape.
 *
 * `Fit` — decided by width, from what the grammar's predicates read off each
 * element: one simple element stays on the declaration's line when that line
 * fits; in a run of several two short neighbours share a line, a long one
 * stands alone, and a short last one stays on the declaration's line; a run
 * of short ones only is one row that breaks one per line when it does not
 * fit; anything else is one per line. A grammar may name predicates over what
 * follows the run that send the lone or the last element to its own line all the same.
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

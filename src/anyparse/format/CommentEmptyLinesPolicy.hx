package anyparse.format;

/**
 * Three-way policy for the blank-line slot adjacent to a doc-commented
 * field (class / interface / abstract / enum member).
 *
 * `Ignore` — respect the source's blank-line count (pre-slice
 * behaviour). The writer emits a blank line only when the parser's
 * `Trivial<T>.blankBefore` flag records one.
 * `None`   — strip any blank line adjacent to the doc-commented field,
 * even when the source carried one.
 * `One`    — always emit exactly one blank line adjacent to the doc-
 * commented field, independent of source. Idempotent: a source that
 * already has one blank line round-trips byte-identical.
 *
 * Consumed by field-scoped writer flags such as
 * `@:fmt(afterFieldsWithDocComments)`: presence of the flag on a
 * trivia-bearing Star field switches the emission loop from honouring
 * only `_t.blankBefore` to a three-way runtime decision driven by the
 * policy. A leading entry starting with `/**` flags the element as
 * doc-commented; line comments (`//`) and non-doc block comments
 * (`/*` without the second `*`) do not trigger the policy.
 *
 * Format-neutral — lives in `anyparse.format` so other grammars with
 * class-like member bodies (AS3, Java, …) can opt into the same policy
 * surface from their own grammar.
 */
enum abstract CommentEmptyLinesPolicy(Int) from Int to Int {

	final Ignore = 0;

	final None = 1;

	final One = 2;
}

package anyparse.format;

/**
 * Two-way policy for the blank-line slots between repeated elements
 * (e.g. class / interface / abstract / enum member fields).
 *
 * `Keep`   — respect the source's blank-line count. The writer emits
 * a blank line exactly when the parser's `Trivial<T>.blankBefore`
 * flag records one. This is the pre-slice default and keeps
 * round-trip byte-identical.
 * `Remove` — strip every blank line between siblings, regardless of
 * what the source had. Produces compact, zero-gap member bodies.
 *
 * Consumed by field-scoped writer flags such as
 * `@:fmt(existingBetweenFields)`: presence of the flag on a
 * trivia-bearing Star field switches the emission loop from honouring
 * only `_t.blankBefore` to a two-way runtime decision driven by the
 * policy. Composes with other blank-line policies on the same slot
 * (e.g. `afterFieldsWithDocComments`): a `None`/`Remove` gate on
 * either side wins — a blank line survives only when every active
 * policy allows it.
 *
 * Format-neutral — lives in `anyparse.format` so other grammars with
 * repeated-member bodies (AS3, Java, …) can opt into the same policy
 * surface from their own grammar.
 */
enum abstract KeepEmptyLinesPolicy(Int) from Int to Int {

	final Keep = 0;

	final Remove = 1;
}

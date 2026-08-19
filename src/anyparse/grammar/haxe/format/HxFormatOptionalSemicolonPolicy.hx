package anyparse.grammar.haxe.format;

/**
 * Closed set of values the `whitespace.optionalSemicolon` key accepts
 * (slice E11 — ω-optional-semicolon).
 *
 * Haxe lets a statement drop its trailing `;` when its last token is
 * `}` (`return { … }`, `var x = switch (v) { … }`). Both forms are
 * legal, nothing in the formatter normalizes them today, and a real
 * corpus drifts between them file by file.
 *
 * - `"preserve"` (default) — the `;` is re-emitted exactly where the
 *   source had one (fork-parity baseline, byte-inert).
 * - `"always"` — every participating slot gets its `;`, so the
 *   terminator does not depend on how the value happens to end. This
 *   also removes a rewrite hazard: a fixer replacing a brace-terminated
 *   value with a non-brace one (`return switch … }` → `return 42`) can
 *   no longer land on a site that has no `;`, where the result is
 *   `Missing ;`.
 * - `"never"` — the `;` is dropped wherever the slot's shape gate
 *   proves it optional; a non-brace value keeps it. Known limitation,
 *   inherited rather than introduced: the writer already drops a blank
 *   line that follows a `;`-less brace-terminated statement (reproduce
 *   on an unpatched build with `if (c)\n\treturn { a: 1 }\n\n\tfinal
 *   q = 2;`), so `"never"` turns a stable file into one that loses a
 *   blank line on the NEXT format pass. Measured over TM: 1 file of 805.
 *   `"preserve"` and `"always"` are both fmt-idempotent there.
 *
 * `"never"` also feeds the width policies a shorter line, so a value
 * that no longer fits — or now does — may re-flow around the dropped
 * byte. Measured over TM: 2 of 125 hunks.
 *
 * Mapped by `HaxeFormatConfigLoader.applyWhitespaceToggles` onto the
 * runtime `HxModuleWriteOptions.optionalSemicolon`
 * (`anyparse.format.OptionalSemicolon`).
 */
enum abstract HxFormatOptionalSemicolonPolicy(String) to String {

	final Preserve = 'preserve';

	final Always = 'always';

	final Never = 'never';

}

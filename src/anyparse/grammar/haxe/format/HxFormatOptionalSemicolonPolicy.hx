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
 *   proves it optional; a non-brace value keeps it.
 *
 * Mapped by `HaxeFormatConfigLoader.applyWhitespaceConfig` onto the
 * runtime `HxModuleWriteOptions.optionalSemicolon`
 * (`anyparse.format.OptionalSemicolon`).
 */
enum abstract HxFormatOptionalSemicolonPolicy(String) to String {

	final Preserve = 'preserve';

	final Always = 'always';

	final Never = 'never';

}

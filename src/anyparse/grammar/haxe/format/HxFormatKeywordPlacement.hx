package anyparse.grammar.haxe.format;

/**
 * Closed set of values the haxe-formatter `sameLine.elseIf` (and
 * other future keyword-placement) fields accept. Mapped by
 * `HaxeFormatConfigLoader` to `anyparse.format.KeywordPlacement`:
 *
 * - `"same"` → `KeywordPlacement.Same` (default) — keyword stays
 *   inline after the preceding token (`} else if (...)`).
 * - `"next"` → `KeywordPlacement.Next` — keyword moves to the next
 *   line at the current indent level (`} else\n\tif (...)`).
 * - `"keep"` → `KeywordPlacement.Same` (degraded — per-node source-
 *   shape tracking not yet available in the parser; `Same` is the
 *   nearest no-surprise fallback).
 * - `"fitLine"` → `KeywordPlacement.Same` (degraded — the writer
 *   has no shape-aware fit mode for lone keywords; the nearest
 *   no-surprise fallback is the inline placement).
 *
 * Mirrors `HxFormatSameLinePolicy` but renders at runtime as a
 * two-value `KeywordPlacement` rather than a `Bool`. The separate
 * type keeps keyword-placement knobs distinct from the existing
 * `Bool`-valued `sameLine.ifElse` / `tryCatch` / `doWhile` fields
 * in the config schema (different JSON vocabulary would otherwise
 * collide).
 */
enum abstract HxFormatKeywordPlacement(String) to String {

	final Same = 'same';

	final Next = 'next';

	final Keep = 'keep';

	final FitLine = 'fitLine';
}

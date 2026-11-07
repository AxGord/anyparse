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
 * - `"keep"` parses so that `HaxeFormatConfigDiagnostics` can name it;
 *   the knob keeps its default.
 * - `"fitLine"` → `KeywordPlacement.FitLine` for `elseSwitch`, `Same`
 *   for `elseIf` (a nested `if` has no fit placement of its own).
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

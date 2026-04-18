package anyparse.format;

/**
 * Four-way whitespace policy for a single-character separator (`:`, `,`,
 * `=>`, …) whose adjacent spacing the format wants to control.
 *
 * `None` — no space on either side (`a:b`). The pre-ψ₇ default for
 * every `@:lead(':')` lead in the Haxe grammar.
 * `Before` — single space before only (`a :b`).
 * `After` — single space after only (`a: b`). This is haxe-formatter's
 * default for `whitespace.objectFieldColonPolicy` and the ψ₇ default
 * for `HxObjectField.value`.
 * `Both` — single space on both sides (`a : b`).
 *
 * Consumed by field-scoped writer metas such as `@:objectFieldColon`:
 * presence of the meta on a lead switches the emission from the plain
 * tight lead (`_dt(':')`) to a runtime switch on the `WriteOptions`
 * flag, so the policy applies only at the tagged site — sibling leads
 * (type-annotation `:` on `HxVarDecl.type` / `HxParam.type` /
 * `HxFnDecl.returnType`) keep their tight emission regardless of the
 * user's configured object-field policy.
 *
 * The four values match the information content the generated writer
 * can actually produce today — haxe-formatter's richer surface
 * (`noneBefore`, `onlyAfter`, `around`, …) collapses onto this set in
 * the loader (`HaxeFormatConfigLoader`) because the extra distinctions
 * only matter to source-shape-tracking, which our parser does not yet
 * carry.
 *
 * Format-neutral — lives in `anyparse.format` so grammars for other
 * languages (AS3, C-family, …) can reuse the same shape for their own
 * single-character separator spacing knobs.
 */
enum abstract WhitespacePolicy(Int) from Int to Int {

	final None = 0;

	final Before = 1;

	final After = 2;

	final Both = 3;
}

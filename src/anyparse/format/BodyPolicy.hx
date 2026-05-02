package anyparse.format;

/**
 * Shared four-way layout policy for control-flow bodies and other
 * fields whose placement relative to the preceding token can vary.
 *
 * `Same` — body sits on the same line as the preceding token,
 * separated by a single space (`if (cond) body;`).
 * `Next` — body is always emitted on the next line at one indent
 * level deeper than the preceding token (`if (cond)\n\tbody;`).
 * `FitLine` — body stays flat if the whole `preceding-token + body`
 * fits within `lineWidth`, otherwise breaks to the next line at one
 * indent level deeper. When the body itself has internal hardlines
 * (multi-line single-expr like `return foo(\n\t...)`), the kw-side
 * break is suppressed: the kw stays inline-with-space and the body
 * wraps using its own internal indent. Only single-line-too-wide
 * bodies trigger the kw-side break + indent.
 * `Keep` — preserve the source shape. The writer reads a per-node
 * boolean captured by the trivia-mode parser and dispatches between
 * `Same` and `Next` layouts at runtime. Two capture paths exist:
 *  - Optional-kw Ref body fields (e.g. `if/else`, `try/catch`):
 *    a synthesised sibling slot `<field>BodyOnSameLine:Bool` records
 *    whether the body's first token followed the keyword on the same
 *    line. Consumed by `bodyPolicyWrap`'s `Keep` branch.
 *  - `@:trivia` Star body fields with `@:fmt(bodyPolicy(...))` (e.g.
 *    `HxCaseBranch.body`, `HxDefaultBranch.stmts`): no synth slot —
 *    the existing `Trivial<T>.newlineBefore` of the first element
 *    carries the same signal (`!newlineBefore` ≡ same-line).
 *    Consumed by `triviaTryparseStarExpr`'s flat-case gate.
 * In plain (non-trivia) parsers neither capture path runs, so `Keep`
 * matches the writer's default layout for the field (the Ref-path
 * fallback emits `Same`, the Star-path is unreachable in plain mode).
 *
 * Consumed by the `@:fmt(bodyPolicy("flagName"))` writer knob: the
 * argument names a `BodyPolicy` field on the generated `WriteOptions`
 * struct and the writer reads it at runtime per node. Format-neutral:
 * the enum lives in `anyparse.format` so grammars for other languages
 * (AS3, Python, …) can reuse the same four-way shape.
 */
enum abstract BodyPolicy(Int) from Int to Int {

	final Same = 0;

	final Next = 1;

	final FitLine = 2;

	final Keep = 3;
}

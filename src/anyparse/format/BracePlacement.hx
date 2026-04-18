package anyparse.format;

/**
 * Two-way placement policy for block-opening braces (`{`).
 *
 * `Same` — the `{` sits on the same line as the preceding token,
 * separated by a single space (`class F {` / `function f() {`). This
 * is the default for every grammar that exposes the knob and matches
 * the pre-ψ₆ behaviour of the writer.
 *
 * `Next` — the `{` is emitted on the next line at the current (outer)
 * indent level, with the body's first line starting one level deeper.
 * Produces the Allman-style layout: `class F\n{\n\tbody\n}`.
 *
 * Consumed by the `@:fmt(leftCurly)` writer flag: presence of the
 * flag on a `@:lead('{')` Star field switches the leading separator
 * to a runtime check against `opt.leftCurly` on the generated
 * `WriteOptions` struct — `Same` keeps the plain space, `Next` emits
 * a hardline at the outer indent. The flag takes no arguments because
 * the knob is global; per-category overrides (type brace vs. block
 * brace vs. object literal) would each introduce their own
 * `@:fmt(<name>)` flag rather than reuse this one with different
 * options fields.
 *
 * Two values are sufficient because the generated `blockBody` layout
 * already places body content after a hardline and the closing `}` on
 * its own line. haxe-formatter's richer `Before` / `Both` collapse to
 * `Next` for our output; `None` (inline `{ ... }`) has no currently
 * exercised use case and would demand source-shape tracking the
 * parser does not yet carry. Additional values can be appended here
 * once a fixture makes them necessary.
 *
 * Format-neutral — lives in `anyparse.format` so grammars for other
 * curly-brace languages (AS3, C-family, …) can reuse the same shape.
 */
enum abstract BracePlacement(Int) from Int to Int {

	final Same = 0;

	final Next = 1;
}

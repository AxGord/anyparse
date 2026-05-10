package anyparse.format;

/**
 * Two-way layout policy for empty curly-brace bodies (`{}`).
 *
 * `Same` — empty body stays flat: `class Foo {}` / `function f() {}`.
 * Default for every grammar that exposes the knob and matches the
 * pre-slice behaviour of the writer.
 *
 * `Break` — empty body breaks across two lines, with the closing `}`
 * sitting on its own line at the parent's indent: `class Foo {\n}`.
 * Mirrors haxe-formatter's `lineEnds.emptyCurly: break`.
 *
 * Consumed by the `@:fmt(emptyCurlyBreak)` writer flag on a `@:trivia
 * @:lead('{') @:trail('}')` Star field: presence of the flag switches
 * the empty-body emission to a runtime check against `opt.emptyCurly`
 * on the generated `WriteOptions` struct — `Same` keeps the flat
 * `{}`, `Break` emits `{` + hardline + `}` at the parent's indent.
 *
 * Format-neutral — lives in `anyparse.format` so grammars for other
 * curly-brace languages (AS3, C-family, …) can reuse the same shape.
 */
enum abstract EmptyCurly(Int) from Int to Int {

	final Same = 0;

	final Break = 1;
}

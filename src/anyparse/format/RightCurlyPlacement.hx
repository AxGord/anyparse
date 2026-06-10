package anyparse.format;

/**
 * Two-way placement policy for block-closing braces (`}`).
 *
 * `Same` — the `}` lands on its own line at the parent indent, with
 * a hardline emitted immediately before it (the standard
 * `{\n\tbody\n}` shape). This is the default for every grammar that
 * exposes the knob and matches the pre-slice behaviour of the writer
 * (haxe-formatter's `Before` / `Both` collapse here — the trailing
 * separator after `}` is already part of the surrounding context).
 *
 * `Inline` — no hardline is emitted before `}`; the close glues to
 * the last body token. Produces the K&R-on-one-line shape:
 * `{ body }`. Mirrors haxe-formatter's `lineEnds.rightCurly: none`
 * (the `after` variant is indistinguishable in our model because the
 * trailing newline after `}` is contributed by the outer sibling
 * separator, not by `blockBody`).
 *
 * Consumed by the `@:fmt(rightCurly)` writer flag on a `@:trivia
 * @:lead('{') @:trail('}')` Star field: presence of the flag (in
 * call-form `@:fmt(rightCurly('<knobName>'))`) switches the
 * before-close hardline to a runtime check against
 * `opt.<knobName>:RightCurlyPlacement` on the generated `WriteOptions`
 * struct — `Same` keeps the hardline, `Inline` drops it.
 *
 * Two values are sufficient because haxe-formatter's `After` and
 * `None` collapse for our model (the trailing-newline-after-`}` slot
 * is outer-sep responsibility), and `Before` / `Both` likewise
 * collapse to `Same`. Additional values can be appended once a
 * fixture demands a richer surface.
 *
 * Format-neutral — lives in `anyparse.format` so grammars for other
 * curly-brace languages (AS3, C-family, ...) can reuse the same shape.
 */
enum abstract RightCurlyPlacement(Int) from Int to Int {

	final Same = 0;

	final Inline = 1;

}

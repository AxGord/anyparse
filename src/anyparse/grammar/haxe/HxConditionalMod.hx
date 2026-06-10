package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <modifiers> #end` preprocessor-guarded modifier
 * region. The enclosing `HxModifier.Conditional` ctor consumes the `#if`
 * keyword and the trailing `#end`; this typedef covers the content
 * between them: the condition atom followed by a try-parse Star of
 * further modifiers.
 *
 * No field-level whitespace literals (e.g. `@:lead(' ')`) — the generated
 * parser calls `skipWs` at every field boundary (`Lowering.lowerStruct`
 * pre-field skipWs, plus the try-parse loop's own `skipWs` before each
 * iteration), so any amount of spacing between `cond`, the modifiers,
 * and `#end` is consumed transparently. A whitespace-prefix literal
 * would never match: the pre-field skipWs runs first and eats the
 * space. Multi-line variants (issue_332 V4 — newline between `cond`
 * and modifier) parse correctly as a consequence; the writer reads
 * the trivia-captured `newlineBefore` to round-trip the shape.
 *
 * `@:tryparse` on `body` puts the Star in try-parse termination mode
 * (`Lowering.emitStarFieldSteps` try-parse branch): the loop parses
 * modifiers until the next token is not a recognised keyword, which in
 * legal input is `#end` — consumed by the outer ctor's `@:trail`.
 *
 * Writer-side output shape: `#if <cond> <modifiers> #end` (V1–V3) or
 * `#if <cond>\n<modifiers>\n#end` (V4 — cond / mods / `#end` on separate
 * source lines). The `#if ` keyword carries its trailing space from
 * `@:kw` + Case 3's `kwLead + ' '` rule, modifiers join internally with
 * single spaces, and the `@:fmt(padLeading, padTrailing)` flag pair on
 * `body` adds a leading + trailing pad around the Star when it is
 * non-empty — closing the cond↔body[0] and body[last]↔`#end` gaps that
 * the default internal-only sep leaves glued against the surrounding
 * `#if`/`#end` tokens. Empty `body` degrades to `_de()` (no padding, no
 * stray space), so a hypothetical `#if cond #end` stays as-is. The two
 * flags are independent — `HxAbstractDecl.clauses` uses
 * `@:fmt(padLeading)` alone because its trailing slot is already
 * covered by the next field's `@:lead('{')` spaced-lead separator.
 *
 * `@:trivia` on `body` makes each modifier element trivia-bearing
 * (`Trivial<HxModifierT>` with a `newlineBefore` slot). The
 * padLeading/padTrailing pads switch from a literal space to a hardline
 * when `body[0].newlineBefore` is set, reproducing the multi-line
 * source shape (issue_332 V4). The trail-side decision mirrors the
 * leading-side because the parser does not capture a body[last]→`#end`
 * newline slot — in legal source shapes the two newlines are
 * correlated. Inter-element separator inside the body keeps its existing
 * per-element `newlineBefore`-driven hardline-vs-space logic in
 * `triviaTryparseStarExpr`.
 */
@:peg
typedef HxConditionalMod = {
	var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing) var body: Array<HxModifier>;
};

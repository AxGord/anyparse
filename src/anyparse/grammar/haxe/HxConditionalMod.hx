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
 * and modifier) parse correctly as a consequence.
 *
 * `@:tryparse` on `body` puts the Star in try-parse termination mode
 * (`Lowering.emitStarFieldSteps` try-parse branch): the loop parses
 * modifiers until the next token is not a recognised keyword, which in
 * legal input is `#end` — consumed by the outer ctor's `@:trail`.
 *
 * Writer-side output shape: `#if <cond> <modifiers> #end`. The `#if `
 * keyword carries its trailing space from `@:kw` + Case 3's `kwLead + ' '`
 * rule, modifiers join internally with single spaces, and the
 * `@:fmt(padBoundaries)` flag on `body` adds a leading + trailing space
 * around the Star when it is non-empty — closing the cond↔body[0] and
 * body[last]↔`#end` gaps that the default internal-only sep leaves glued
 * against the surrounding `#if`/`#end` tokens. Empty `body` degrades to
 * no padding, so a hypothetical `#if cond #end` stays as-is rather than
 * gaining a stray space.
 */
@:peg
typedef HxConditionalMod = {
	var cond:HxPpCondLit;
	@:tryparse @:fmt(padBoundaries) var body:Array<HxModifier>;
};

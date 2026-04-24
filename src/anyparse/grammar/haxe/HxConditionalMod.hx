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
 * Writer-side output shape today: `#if <cond><modifiers-joined-by-space>#end`.
 * The `#if ` keyword carries a trailing space (from `@:kw` + Case 3's
 * `kwLead + ' '` rule), and modifiers get internal single-space
 * separators (try-parse Star writer), but there is NO space between
 * `cond` and the first modifier, and NO space between the last modifier
 * and `#end`. Corpus parity against haxe-formatter's expected
 * `#if <cond> <modifiers> #end` needs a writer-side boundary-space
 * mechanism and is deferred to a follow-up slice; probe tests here only
 * assert round-trip-idempotent parsing.
 */
@:peg
typedef HxConditionalMod = {
	var cond:HxPpCondLit;
	@:tryparse var body:Array<HxModifier>;
};

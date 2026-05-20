package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <params> [#elseif …] [#else <params>] #end`
 * preprocessor-guarded region wrapping whole function-parameter entries.
 * The fn-param-scope twin of `HxConditionalObjectField` (Slice 18) /
 * `HxConditionalMember` / `HxConditionalStmt` / `HxConditionalDecl`: the
 * enclosing `HxParam.Conditional` ctor consumes the `#if` keyword and the
 * trailing `#end`; this typedef covers the content between them — the
 * condition atom, the then-body Star of further `HxParam` entries, an
 * optional `#elseif` clause chain, and an optional `#else` clause with
 * its own param Star.
 *
 * `body` Star uses Slice 18's `@:sep(',') @:tryparse` (no `@:trail`)
 * Lowering branch: comma-separated `HxParam` elements terminated by
 * fail-rewind. The first `parseHxParam` call that hits `#end` (no
 * `Required`/`Optional`/`Rest` dispatch and no `#if` ctor for nesting)
 * throws; the outer Star's `_savedPos` rewind restores the position so
 * the enclosing `HxParam.Conditional` ctor's `@:trail('#end')` sees `#end`
 * at its native offset. Empty bodies (`#if X #end` with zero params) are
 * ACCEPTED — `HxParam` is a bare sum-type, no mandatory wrapping struct
 * (same divergence as `HxObjectField` from the member-scope precedent).
 *
 * The body's `@:tryparse` Star naturally terminates after at least one
 * element when the next token is not a recognised `HxParam` dispatch —
 * `#elseif`, `#else`, and `#end` fail every branch's dispatch token, so
 * the loop stops cleanly. Nested `#if` is supported transitively: a
 * `HxParam.Conditional` re-entry inside the body is just another elem.
 *
 * Outer-Star sep-elide (no comma between adjacent `Conditional` and
 * sibling params, e.g. `false #if A, B #end` or `#if A #end foobar`) is
 * handled at runtime — the `@:trivia @:sep @:trail`-Star wrapping
 * `HxFnDecl.params` records per-element `sepAfter:Bool` from the parser's
 * `matchLit(sep)` result. When the source omits the comma, `sepAfter=false`
 * propagates to the writer's `_emitSep` gate (`triviaSepStarExpr`), which
 * suppresses the inter-element comma. No new Lowering / Writer primitive
 * is required — Slice 18a piggybacks on the same mechanism that closed
 * lineends/issue_111.
 *
 * `body` and `elseBody` carry `@:fmt(padLeading, padTrailing)` — same
 * pad pair as the member-scope and obj-lit-scope precedents — closing the
 * boundary gaps between `#if <cond>` / `#else` / `#end` and the contained
 * param run. No blank-line cascades are mirrored: fn parameters have no
 * grouping analogue at this scope, and inter-element trivia is the outer
 * `HxFnDecl.params` Star's job (`@:trivia` there).
 *
 * Trivia note (Slice 18 carry-over): this body Star deliberately does NOT
 * carry `@:trivia`. Lowering rejects `@:trivia + @:sep + @:tryparse` (no
 * current grammar combines them; the semantics of "trivia around a
 * sep-separated tryparse list" are undecided — Slice 18d follow-up).
 * Practical consequence: comments INSIDE a `#if … #end` param-list body
 * parse but do not round-trip byte-identical. Comments around the WHOLE
 * `Conditional` element (above `#if`, below `#end`) are preserved by
 * the outer `HxFnDecl.params` Star.
 *
 * `elseBody` is `@:optional @:kw('#else') @:tryparse` (no `@:sep` — the
 * `emitOptionalKwStarFieldSteps` Lowering path does NOT yet support sep
 * peek; extending it is the deferred Slice 18e). Consequence: a
 * comma-separated body inside `#else` will fail-rewind after the first
 * param if there's a comma waiting — the multi-field `#else` case lands
 * in fail not pass for the campaign metric, the single-field case works.
 */
@:peg
typedef HxConditionalParam = {
	var cond:HxPpCondLit;
	@:sep(',') @:tryparse @:fmt(padLeading, padTrailing) var body:Array<HxParam>;
	@:tryparse var elseifs:Array<HxElseifParam>;
	@:optional @:kw('#else') @:tryparse @:fmt(padLeading, padTrailing) var elseBody:Null<Array<HxParam>>;
};

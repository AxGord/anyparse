package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <decls> [#else <decls>] #end` preprocessor-
 * guarded module-level region. Mirror of `HxConditionalMod` at the
 * top-level declaration scope: the enclosing `HxDecl.Conditional` ctor
 * consumes the `#if` keyword and the trailing `#end`; this typedef
 * covers the content between them — the condition atom, the then-body
 * Star of further declarations, and an optional `#else` clause with
 * its own decl Star.
 *
 * Element type is `HxTopLevelDecl` (not bare `HxDecl`) so leading
 * metadata + modifiers inside the conditional region parse uniformly:
 * `#if cond @:meta private class Foo {} #end` works through the same
 * meta + modifier Stars used at module top level. The body's
 * `@:tryparse` Star terminates when the next token isn't a recognised
 * `HxTopLevelDecl` start — `#else` and `#end` fail every modifier and
 * decl-keyword dispatch path, so the loop naturally stops there.
 *
 * Nested `#if` is supported transitively through the body re-entering
 * `HxDecl.Conditional` via the dispatch enum's `@:kw('#if')` ctor.
 *
 * `#elseif` is intentionally out of scope for this slice — fixtures
 * in the imports_and_using_* cluster only use `#if … #else … #end`.
 * Adding `#elseif` would require a chained-clause shape (one `#if`
 * head + Star of `#elseif` clauses + optional `#else` tail) and is
 * deferred to a follow-up slice.
 *
 * Writer-side output mirrors `HxConditionalMod`: the
 * `@:fmt(padLeading, padTrailing)` flag pair on `body` and `elseBody`
 * adds a leading + trailing pad around each Star when non-empty,
 * closing the `#if`/`#else`/`#end` boundary gaps that the default
 * internal-only sep leaves glued. The pads switch from a literal space
 * to a hardline when the first body element's `newlineBefore` slot is
 * set (captured via `@:trivia`), reproducing the multi-line shape the
 * fork's import fixtures exercise (`#if php\nimport php.Lib;\n#end`).
 *
 * `@:optional @:kw('#else') @:tryparse var elseBody:Null<Array<…>>`
 * uses the kw-led optional Star path (Lowering's
 * `emitOptionalKwStarFieldSteps`, slice ω-cond-comp-engine). The path
 * splices the kw-Ref commit machinery with the tryparse Star loop —
 * `#else` is the commit point, miss leaves the field `null` so the
 * writer skips the entire clause. Direct path eliminates the
 * pre-engine-slice Ref-wrapper companion typedef (one extra fn frame
 * + wrapper struct alloc per `#else` hit + extra paired `*T` synth).
 */
@:peg
typedef HxConditionalDecl = {
	var cond:HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing) var body:Array<HxTopLevelDecl>;
	@:optional @:kw('#else') @:trivia @:tryparse @:fmt(padLeading, padTrailing) var elseBody:Null<Array<HxTopLevelDecl>>;
};

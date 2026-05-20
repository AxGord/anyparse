package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <fields> [#elseif …] [#else <fields>] #end`
 * preprocessor-guarded region wrapping whole object-literal field
 * entries. The object-literal-scope twin of `HxConditionalMember` /
 * `HxConditionalStmt` / `HxConditionalDecl`: the enclosing
 * `HxObjectField.Conditional` ctor consumes the `#if` keyword and the
 * trailing `#end`; this typedef covers the content between them — the
 * condition atom, the then-body Star of further object-literal fields,
 * an optional `#elseif` clause chain, and an optional `#else` clause
 * with its own field Star.
 *
 * `body` Star uses Slice 18's `@:sep(',') @:tryparse` (no `@:trail`)
 * Lowering branch: comma-separated `HxObjectField` elements terminated
 * by fail-rewind. The first `parseHxObjectField` call that hits `#end`
 * (no name terminal, no `#if` ctor) throws; the outer Star's `_savedPos`
 * rewind restores the position so the enclosing
 * `HxObjectField.Conditional` ctor's `@:trail('#end')` sees `#end` at
 * its native offset. Empty bodies (`#if X #end` with zero fields) are
 * therefore ACCEPTED, unlike `HxConditionalMember` where the inner
 * `HxMemberDecl`'s mandatory `member:HxClassMember` field throws before
 * the tryparse Star can roll back to zero elements (`HxObjectField` is
 * a bare sum-type with no mandatory wrapping struct).
 *
 * The body's `@:tryparse` Star naturally terminates after at least one
 * field when the next token is not a recognised `HxObjectField`
 * dispatch — `#elseif`, `#else`, and `#end` fail the name terminal AND
 * the `#if` ctor's kw match, so the loop stops cleanly.
 *
 * Nested `#if` is supported transitively because each `HxObjectField`
 * element re-enters via the `Conditional(HxConditionalObjectField)`
 * ctor.
 *
 * `body` and `elseBody` carry `@:fmt(padLeading, padTrailing)` — same
 * pad pair as the member-scope precedent — closing the boundary gaps
 * between `#if <cond>` / `#else` / `#end` and the contained field run.
 * No blank-line cascades are mirrored (the decl-scope import-grouping
 * cascades on `HxConditionalDecl.body` have no meaning at field scope;
 * inter-element trivia is the outer `HxObjectLit.fields` Star's job).
 *
 * Trivia note: this body Star deliberately does NOT carry `@:trivia`.
 * Lowering rejects `@:trivia + @:sep + @:tryparse` (no current grammar
 * combines them and the semantics of "trivia around a sep-separated
 * tryparse list" are undecided — Slice 18 follow-up). Practical
 * consequence: comments INSIDE a `#if … #end` field-list body parse
 * but do not round-trip byte-identical. The outer `HxObjectLit.fields`
 * Star is `@:trivia`-bearing so trivia around the whole `Conditional`
 * element (above the `#if`, below the `#end`) is preserved verbatim.
 *
 * `elseBody` is `@:optional @:kw('#else') @:tryparse` (no `@:sep` — the
 * `emitOptionalKwStarFieldSteps` Lowering path does NOT yet support sep
 * peek; extending it is a Slice 18 follow-up). Consequence: a comma-
 * separated body inside `#else` will fail-rewind after the first field
 * if there's a comma waiting — the multi-field `#else` case lands in
 * fail not pass for the campaign metric, the single-field case works.
 */
@:peg
typedef HxConditionalObjectField = {
	var cond:HxPpCondLit;
	@:sep(',') @:tryparse @:fmt(padLeading, padTrailing) var body:Array<HxObjectField>;
	@:tryparse var elseifs:Array<HxElseifObjectField>;
	@:optional @:kw('#else') @:tryparse @:fmt(padLeading, padTrailing) var elseBody:Null<Array<HxObjectField>>;
};

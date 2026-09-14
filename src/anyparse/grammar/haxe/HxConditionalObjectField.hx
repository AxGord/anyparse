package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <fields> [#elseif …] [#else <fields>] #end` preprocessor-guarded
 * region wrapping whole object-literal field entries — the object-literal-scope twin of
 * `HxConditionalMember` / `HxConditionalStmt` / `HxConditionalDecl`. The enclosing
 * `HxObjectField.Conditional` ctor consumes the `#if` keyword and the trailing `#end`; this
 * typedef covers the content between them — the condition atom, the then-body Star, an
 * optional `#elseif` chain, and an optional `#else` clause with its own field Star.
 *
 * `body` uses the `@:sep(',') @:tryparse` (no `@:trail`) Lowering branch: comma-separated
 * `HxObjectField` elements terminated by fail-rewind. The first `parseHxObjectField` call
 * that hits `#end` (no name terminal, no `#if` ctor) throws; the outer Star's `_savedPos`
 * rewind restores the position so the enclosing ctor's `@:trail('#end')` sees `#end` at its
 * native offset. Empty bodies (`#if X #end`) are therefore ACCEPTED, unlike
 * `HxConditionalMember`, where the inner `HxMemberDecl`'s mandatory `member` field throws
 * before the tryparse Star can roll back to zero elements. The Star terminates after at
 * least one field when the next token is not a recognised `HxObjectField` dispatch —
 * `#elseif`, `#else` and `#end` fail the name terminal AND the `#if` ctor's kw match. Nested
 * `#if` is supported transitively because each element re-enters via the
 * `Conditional(HxConditionalObjectField)` ctor.
 *
 * `body` and `elseBody` carry `@:fmt(padLeading, padTrailing)` — the member-scope pad pair —
 * closing the boundary gaps between `#if <cond>` / `#else` / `#end` and the contained field
 * run. No blank-line cascades are mirrored: inter-element trivia is the outer
 * `HxObjectLit.fields` Star's job.
 *
 * This body Star deliberately does NOT carry `@:trivia`: Lowering rejects `@:trivia + @:sep +
 * @:tryparse` (the semantics of trivia around a sep-separated tryparse list are undecided),
 * so comments INSIDE a `#if … #end` field-list body parse but do not round-trip
 * byte-identical; trivia around the whole `Conditional` element is preserved by the outer
 * `@:trivia`-bearing `HxObjectLit.fields` Star.
 *
 * `elseBody` is `@:optional @:kw('#else') @:tryparse` with no `@:sep` — the
 * `emitOptionalKwStarFieldSteps` Lowering path does not support a sep peek — so a
 * comma-separated body inside `#else` fail-rewinds after its first field when a comma is
 * waiting; the single-field `#else` works.
 */
@:peg
typedef HxConditionalObjectField = {
	var cond: HxPpCondLit;
	@:trivia @:sep(',', sepFaithful) @:tryparse @:fmt(padLeading, padTrailing, sepBeforeOpt, conditionalBodyIndent)
	var body: Array<HxObjectField>;
	@:tryparse var elseifs: Array<HxElseifObjectField>;
	@:optional @:kw('#else') @:trivia @:sep(',', sepFaithful) @:tryparse
	@:fmt(padLeading, padTrailing, conditionalBodyIndent) var elseBody: Null<Array<HxObjectField>>;
};

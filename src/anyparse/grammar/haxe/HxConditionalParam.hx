package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <params> [#elseif …] [#else <params>] #end` preprocessor-guarded
 * region wrapping whole function-parameter entries — the fn-param-scope twin of
 * `HxConditionalObjectField` / `HxConditionalMember`. The enclosing `HxParam.Conditional`
 * ctor consumes the `#if` keyword and the trailing `#end`; this typedef covers the content
 * between them.
 *
 * `body` uses the `@:sep(',') @:tryparse` (no `@:trail`) Lowering branch: comma-separated
 * `HxParam` elements terminated by fail-rewind. The first `parseHxParam` call that hits
 * `#end` throws; the outer Star's `_savedPos` rewind restores the position so the enclosing
 * ctor's `@:trail('#end')` sees `#end` at its native offset. Empty bodies (`#if X #end`) are
 * ACCEPTED — `HxParam` is a bare sum-type with no mandatory wrapping struct. The Star
 * terminates when the next token is not a recognised `HxParam` dispatch (`#elseif`, `#else`,
 * `#end`); nested `#if` is just another `HxParam.Conditional` element.
 *
 * `@:fmt(sepBeforeOpt)` tolerates a LEADING separator INSIDE the body, between `#if <cond>`
 * and the first element (`#if air, commandKey:Bool = false, ...`): a pre-loop sep-peek
 * consumes the leading `,` into a `bodySepBefore:Bool` synth slot, and the body's
 * padLeading branch swaps `_dt(' ')` for `_dt(', ')` when it is true. Symmetric with
 * `Trivial.sepAfter` (per-element post-sep) and `<field>TrailPresent` (pre-close) — three
 * orthogonal sep-position knobs over a sep-tryparse Star. The outer-Star sep-elide (no
 * comma between a `Conditional` and a sibling param, `false #if A, B #end`) is handled at
 * runtime by `HxFnDecl.params`'s per-element `sepAfter` and the writer's `_emitSep` gate.
 *
 * `body` and `elseBody` carry `@:fmt(padLeading, padTrailing)`, closing the boundary gaps
 * against `#if <cond>` / `#else` / `#end`; inter-element trivia is `HxFnDecl.params`'s job.
 *
 * Both bodies carry `@:sep(',', sepFaithful)`, for two different reasons. On `body` (with
 * `@:trivia`, the trio `HxConditionalArgs.body` uses) `sepFaithful` is what makes a separator
 * INSIDE the region round-trip: `#if js ?parentDom:String, #end` writes the trailing comma
 * back where the source put it. Without it the tryparse rewind swallowed that comma and the
 * outer Star emitted none either (its own `sepAfter` is false), so under `-D js` the output
 * read two parameters with no separator — output that PARSES here, so the round-trip gate
 * never saw it; only the Haxe compiler did. On `elseBody` (`@:optional @:kw('#else')
 * @:tryparse`) the flag is what makes a sep legal on the `emitOptionalKwStarFieldSteps` path:
 * that path rejects a bare `@:sep` because termination is undefined without either
 * `blockEnded(...)` or per-element `sepAfter` capture, and `sepFaithful` supplies the latter;
 * without any sep a comma-separated `#else` body fail-rewound after its first param
 * (`#else direction:TextDirection = LEFT_TO_RIGHT, script:TextScript = COMMON #end`).
 */
@:peg
typedef HxConditionalParam = {
	var cond: HxPpCondLit;
	@:trivia @:sep(',', sepFaithful) @:tryparse @:fmt(padLeading, padTrailing, sepBeforeOpt, softFill) var body: Array<HxParam>;
	@:tryparse var elseifs: Array<HxElseifParam>;
	@:optional @:kw('#else') @:sep(',', sepFaithful) @:tryparse @:fmt(padLeading, padTrailing) var elseBody: Null<Array<HxParam>>;
};

package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <params> [#elseif …] [#else <params>] #end`
 * preprocessor-guarded region wrapping whole function-parameter entries.
 * The fn-param-scope twin of `HxConditionalObjectField` /
 * `HxConditionalMember` / `HxConditionalStmt` / `HxConditionalDecl`: the
 * enclosing `HxParam.Conditional` ctor consumes the `#if` keyword and the
 * trailing `#end`; this typedef covers the content between them — the
 * condition atom, the then-body Star of further `HxParam` entries, an
 * optional `#elseif` clause chain, and an optional `#else` clause with
 * its own param Star.
 *
 * `body` Star uses the `@:sep(',') @:tryparse` (no `@:trail`) Lowering
 * branch: comma-separated `HxParam` elements terminated by fail-rewind.
 * The first `parseHxParam` call that hits `#end` (no
 * `Required`/`Optional`/`Rest` dispatch and no `#if` ctor for nesting)
 * throws; the outer Star's `_savedPos` rewind restores the position so
 * the enclosing `HxParam.Conditional` ctor's `@:trail('#end')` sees `#end`
 * at its native offset. Empty bodies (`#if X #end` with zero params) are
 * ACCEPTED — `HxParam` is a bare sum-type, no mandatory wrapping struct
 * (same divergence as `HxObjectField` from the member-scope precedent).
 *
 * `@:fmt(sepBeforeOpt)` opt-in: tolerates a LEADING separator INSIDE the
 * body, between `#if <cond>` and the first body element —
 * `#if air, commandKey:Bool = false, ...` (fork fixture
 * `whitespace/issue_582_type_hints_conditionals`). Parser-side: a
 * pre-loop sep-peek consumes the leading `,` and stores the result in a
 * `bodySepBefore:Bool` synth slot on the paired type. Writer-side: the
 * body's padLeading branch (`@:fmt(padLeading)` below) swaps the
 * default `_dt(' ')` for `_dt(', ')` when `bodySepBefore` is true, re-
 * emitting the leading sep for byte-roundtrip. The combined slot+writer
 * mechanism is symmetric with `Trivial.sepAfter` (per-element post-sep
 * flag) and `<field>TrailPresent` (post-last-element pre-close flag) —
 * three orthogonal sep-position knobs covering the leading /
 * inter-element / trailing slots of a sep-tryparse Star.
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
 * suppresses the inter-element comma — no dedicated Lowering / Writer
 * primitive involved.
 *
 * `body` and `elseBody` carry `@:fmt(padLeading, padTrailing)` — same
 * pad pair as the member-scope and obj-lit-scope precedents — closing the
 * boundary gaps between `#if <cond>` / `#else` / `#end` and the contained
 * param run. No blank-line cascades are mirrored: fn parameters have no
 * grouping analogue at this scope, and inter-element trivia is the outer
 * `HxFnDecl.params` Star's job (`@:trivia` there).
 *
 * Trivia note: this body Star deliberately does NOT carry `@:trivia`.
 * Lowering rejects `@:trivia + @:sep + @:tryparse` (no current grammar
 * combines them; the semantics of "trivia around a sep-separated
 * tryparse list" are undecided). Practical consequence: comments INSIDE
 * a `#if … #end` param-list body parse but do not round-trip
 * byte-identical. Comments around the WHOLE `Conditional` element
 * (above `#if`, below `#end`) are preserved by the outer
 * `HxFnDecl.params` Star.
 *
 * `elseBody` is `@:optional @:kw('#else') @:sep(',', sepFaithful)
 * @:tryparse`. The `sepFaithful` flag is what makes the sep legal on the
 * `emitOptionalKwStarFieldSteps` path: that path rejects a bare `@:sep`
 * because termination is undefined without either `blockEnded(...)` or
 * per-element `sepAfter` capture, and `sepFaithful` supplies the latter —
 * permissive `matchLit` on the separator, writer-side re-emission keyed
 * purely on the captured signal. Same annotation as the call-arg twin
 * `HxConditionalArgs.elseBody`.
 *
 * Before that flag was added the field carried no `@:sep` at all, so a
 * comma-separated `#else` body fail-rewound after its first param and only
 * the single-param case parsed. Two openfl signatures depend on the
 * multi-param form: `TextLayout.new` (`#else direction:TextDirection =
 * LEFT_TO_RIGHT, script:TextScript = COMMON, language:String = "en" #end`)
 * and `Stage.new` (`#else window:Window, color:Null<Int> = null #end`).
 *
 * `body` keeps its plain `@:sep(',')`: it is not kw-led, so it lowers
 * through the ordinary sep-tryparse branch where a bare separator is
 * already well-defined.
 */
@:peg
typedef HxConditionalParam = {
	var cond: HxPpCondLit;
	@:sep(',') @:tryparse @:fmt(padLeading, padTrailing, sepBeforeOpt, softFill) var body: Array<HxParam>;
	@:tryparse var elseifs: Array<HxElseifParam>;
	@:optional @:kw('#else') @:sep(',', sepFaithful) @:tryparse @:fmt(padLeading, padTrailing) var elseBody: Null<Array<HxParam>>;
};

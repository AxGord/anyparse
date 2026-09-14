package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <fields> [#elseif ...] [#else <fields>] #end` preprocessor-guarded
 * region wrapping whole fields of an ANONYMOUS STRUCTURE TYPE. The enclosing
 * `HxAnonField.Conditional` ctor consumes the `#if` keyword and the trailing `#end`; this
 * typedef covers the content between them — the condition atom, the then-body Star of further
 * anon members, an optional `#elseif` chain, and an optional `#else` clause with its own Star.
 *
 * Type-level sibling of `HxConditionalObjectField`, which does the same job for an object
 * LITERAL. The two cannot share a body typedef: the object-literal scope holds `HxObjectField`
 * elements separated by a mandatory `,`, while an anon-type field run is `HxAnonMember` whose
 * elements terminate themselves with `;` through `HxAnonField.VarField`'s `@:trailOpt(';')`:
 *
 * ```haxe
 * typedef Data = {
 *     var pixels : haxe.io.Bytes;
 * #if (haxe_ver < 4)
 *     var colorTable : Null<haxe.io.Bytes>;
 * #else
 *     var ?colorTable : haxe.io.Bytes;
 * #end
 * }
 * ```
 *
 * The Stars hold `HxAnonMember` rather than the bare `HxAnonField` kind-dispatch enum because
 * a guarded field carries its own `@:optional` tag and doc comment, both on the wrapper.
 *
 * No `@:sep`: the `;`-terminated class notation's terminator is already consumed by
 * `HxAnonField.VarField` / `FinalField`'s `@:trailOpt(';')`, so a separator peek has nothing
 * to do. A comma-separated SHORT-form body (`#if x a:Int, b:Int #end`) therefore stops after
 * its first field and the region fails to parse; a `@:sep(',', sepFaithful)` would make the
 * separator mandatory between the `;`-terminated elements real source does use, trading
 * working modules for a shape no dependency tree contains.
 *
 * `@:tryparse` termination: the body loop breaks when the next token starts neither a field
 * nor a nested `#if` — in legal input `#elseif` / `#else` / `#end`, consumed by the following
 * field / the outer ctor's `@:trail`. `@:fmt(padLeading, padTrailing)` on the Stars closes
 * the boundary gaps against `#if <cond>` / `#else` / `#end`, the pad pair of the
 * `HxConditionalHeritage` / `HxConditionalObjectField` precedents; empty Stars degrade to
 * `_de()`.
 */
@:peg
typedef HxConditionalAnonField = {
	var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing) var body: Array<HxAnonMember>;
	@:trivia @:tryparse @:fmt(elemSelfTrailsNewline) var elseifs: Array<HxElseifAnonField>;
	@:optional @:kw('#else') @:trivia @:tryparse @:fmt(padLeading, padTrailing) var elseBody: Null<Array<HxAnonMember>>;
};

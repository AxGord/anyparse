package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <heritage clauses> [#elseif ...] [#else ...] #end`
 * preprocessor-guarded region in heritage position. The enclosing
 * `HxHeritageClause.Conditional` ctor consumes the `#if` keyword and the
 * trailing `#end`; this typedef covers the content between them — the
 * condition atom, a try-parse Star of further clauses, the `#elseif`
 * chain, and an optional `#else` clause with its own Star.
 *
 * Heritage-scope sibling of `HxConditionalMod` (modifier run) and
 * `HxConditionalMeta` (declaration prefix). Motivating shapes, 9 of
 * openfl's remaining unparseable modules:
 *
 * ```haxe
 * class Window #if lime extends LimeWindow #end
 * class Stage extends DisplayObjectContainer #if lime implements IModule #end
 * class Error #if (haxe_ver >= "4.1.0") extends haxe.Exception
 *             #elseif (openfl_dynamic && haxe_ver < "4.0.0") implements Dynamic #end
 * ```
 *
 * Distinct from `HxConditionalType`, which already covers a conditional
 * in the TYPE slot of a clause (`extends #if x A #else B #end`): here
 * the `extends` / `implements` keyword itself lives inside the region,
 * so the conditional must be an element of the heritage Star rather
 * than of the type it names. The two compose — a conditional clause may
 * carry a conditional type.
 *
 * `@:tryparse` termination: the body loop attempts a clause each
 * iteration and breaks when the next token is neither `extends`,
 * `implements`, nor a nested `#if` — in legal input that terminator is
 * `#elseif` / `#else` / `#end`, consumed by the following field / the
 * outer ctor's `@:trail`.
 *
 * `@:fmt(padLeading, padTrailing)` on the Stars closes the boundary gaps
 * against `#if <cond>` / `#else` / `#end`, the same pad pair as the
 * `HxConditionalMod` precedent; empty Stars degrade to `_de()`.
 */
@:peg
typedef HxConditionalHeritage = {
	var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing) var body: Array<HxHeritageClause>;
	@:trivia @:tryparse @:fmt(elemSelfTrailsNewline) var elseifs: Array<HxElseifHeritage>;
	@:optional @:kw('#else') @:trivia @:tryparse @:fmt(padLeading, padTrailing) var elseBody: Null<Array<HxHeritageClause>>;
};

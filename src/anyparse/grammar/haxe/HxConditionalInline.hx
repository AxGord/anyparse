package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <elements> [#elseif ...] [#else ...] #end` preprocessor-guarded region
 * that wraps whole ELEMENTS of a list with no separator (modifiers, metadata, heritage clauses,
 * abstract clauses, anonymous-structure members); the host ctor consumes `#if` and the trailing
 * `#end`. Every instance shares one layout policy: entries join with single spaces, each Star
 * carries `@:fmt(padLeading, padTrailing)`, and the pads switch from a space to a hardline when
 * `body[0].newlineBefore` is set, the trail side mirroring the leading side because the parser
 * captures no `body[last]` to `#end` newline slot. Which list claims a given region is decided
 * by field order in the host, not by lookahead.
 *
 * KNOWN WRITER GAPS, shared by every instance: an EMPTY Star degrades to `_de()` and drops the
 * pad entirely (`#if a#end`); a non-empty `#elseif` body is followed by a DOUBLE space, since
 * its own padTrailing runs in addition to the next `@:kw`'s separator.
 */
@:peg
typedef HxConditionalInline<T> = {
	var cond: HxPpCondLit;
	@:trivia
	@:tryparse
	@:fmt(padLeading, padTrailing)
	var body: Array<T>;
	@:trivia
	@:tryparse
	@:fmt(elemSelfTrailsNewline)
	var elseifs: Array<HxElseifInline<T>>;
	@:optional
	@:kw('#else')
	@:trivia
	@:tryparse
	@:fmt(padLeading, padTrailing)
	var elseBody: Null<Array<T>>;
};

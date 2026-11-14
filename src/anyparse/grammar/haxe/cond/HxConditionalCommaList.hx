package anyparse.grammar.haxe.cond;

/**
 * Body of a `#if <cond> <list> [#elseif …] [#else <list>] #end` region that wraps whole ELEMENTS of a
 * comma-separated list of `T`; the host ctor consumes `#if` and the trailing `#end`. Every
 * instance shares one layout policy: the body keeps a leading `,` (`sepBeforeOpt`, the
 * `g(true #if X, true #end)` shape, glued `#if` included) and each branch, `#else` with its own
 * trailing comma, indents as a conditional body. The outer list's sep elision around the group rides
 * the per-element `sepAfter` capture.
 */
@:peg
typedef HxConditionalCommaList<T> = {
	var cond: HxPpCondLit;
	@:trivia
	@:sep(',', sepFaithful)
	@:tryparse
	@:fmt(padLeading, padTrailing, sepBeforeOpt, conditionalBodyIndent)
	var body: Array<T>;
	@:tryparse
	var elseifs: Array<HxElseifCommaList<T>>;
	@:optional
	@:kw('#else')
	@:trivia
	@:sep(',', sepFaithful)
	@:tryparse
	@:fmt(padLeading, padTrailing, conditionalBodyIndent)
	var elseBody: Null<Array<T>>;
};

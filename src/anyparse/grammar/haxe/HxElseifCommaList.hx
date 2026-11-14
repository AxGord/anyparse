package anyparse.grammar.haxe;

/**
 * One `#elseif <cond> <list>` clause of a `HxConditionalCommaList<T>` chain: the `#elseif` keyword
 * commits the clause, the condition atom follows, and the body is a comma-separated try-parse Star of
 * `T` elements ended by the next `#elseif` / `#else` / `#end`.
 */
@:peg
typedef HxElseifCommaList<T> = {
	@:kw('#elseif')
	var cond: HxPpCondLit;
	@:trivia
	@:sep(',', sepFaithful)
	@:tryparse
	@:fmt(padLeading, padTrailing, conditionalBodyIndent)
	var body: Array<T>;
};

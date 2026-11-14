package anyparse.grammar.haxe.cond;

/**
 * One `#elseif <cond> <elements>` clause of a `HxConditionalInline<T>` chain: the `#elseif`
 * keyword commits the clause, the condition atom follows, and the body is a try-parse Star of `T`
 * ended by the next `#elseif` / `#else` / `#end`.
 */
@:peg
typedef HxElseifInline<T> = {
	@:kw('#elseif')
	var cond: HxPpCondLit;
	@:trivia
	@:tryparse
	@:fmt(padLeading, padTrailing)
	var body: Array<T>;
};

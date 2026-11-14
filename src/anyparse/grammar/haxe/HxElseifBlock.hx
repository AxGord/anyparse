package anyparse.grammar.haxe;

/**
 * One `#elseif <cond> <blocks>` clause of a `HxConditionalBlock<T>` chain. The keyword sits on the
 * first field so the parent's Star stops at the first token that is not `#elseif`; the parent
 * declares `elseifs` before `elseBody` so the clauses end before the `#else` dispatch.
 */
@:peg
typedef HxElseifBlock<T> = {
	@:kw('#elseif')
	var cond: HxPpCondLit;
	@:trivia
	@:tryparse
	@:fmt(padLeading, padTrailing, conditionalBodyIndent, elementPerLine,
		siblingPad('anyparse.format.SiblingShare.padSlot', 'conditionalSiblings'))
	var body: Array<T>;
};

package anyparse.grammar.haxe;

/**
 * One `#elseif <cond> <case clauses>` clause inside a
 * `HxConditionalCase` chain. Case-scope twin of `HxElseifInline<HxCondDeclPrefix>`.
 */
@:peg
typedef HxElseifCase = {
	@:kw('#elseif')
	var cond: HxPpCondLit;
	@:trivia
	@:tryparse
	@:fmt(padLeading, padTrailing, conditionalBodyIndent, elementPerLine,
		siblingPad('anyparse.format.SiblingShare.padSlot', 'conditionalSiblings'))
	var body: Array<HxSwitchCase>;
};

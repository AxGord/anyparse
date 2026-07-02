package anyparse.grammar.haxe;

/**
 * One `#elseif <cond> <case clauses>` clause inside a
 * `HxConditionalCase` chain. Case-scope twin of `HxElseifMeta`.
 */
@:peg
typedef HxElseifCase = {
	@:kw('#elseif') var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing, conditionalBodyIndent) var body: Array<HxSwitchCase>;
};

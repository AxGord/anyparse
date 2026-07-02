package anyparse.grammar.haxe;

/**
 * One `#elseif <cond> <expr-list>` clause inside a `HxConditionalArgs`
 * chain. Expr-list-scope twin of `HxElseifParam`: the `#elseif`
 * keyword commits the clause, the condition atom follows, and the
 * body is a comma-separated try-parse Star of expression elements
 * terminated by the next `#elseif` / `#else` / `#end` token.
 */
@:peg
typedef HxElseifArgs = {
	@:kw('#elseif') var cond: HxPpCondLit;
	@:trivia @:sep(',', sepFaithful) @:tryparse @:fmt(padLeading, padTrailing, conditionalBodyIndent) var body: Array<HxExpr>;
};

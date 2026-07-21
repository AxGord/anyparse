package anyparse.grammar.haxe;

/**
 * One `#elseif <cond> <decl-prefix entries>` clause inside a
 * `HxConditionalMeta` chain. Metadata-scope twin of `HxElseifParam`:
 * the `#elseif` keyword commits the clause, the condition atom
 * follows, and the body is a try-parse Star of `HxCondDeclPrefix`
 * entries terminated by the next `#elseif` / `#else` / `#end` token.
 * The element type tracks `HxConditionalMeta`'s Stars so a keyword-
 * bearing branch parses in any arm of the chain, not just the first.
 * Live dogfood shape: --
 * `#if mac @:cppFileCode('...') #elseif windows @:cppFileCode('...') #end`.
 */
@:peg
typedef HxElseifMeta = {
	@:kw('#elseif') var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing) var body: Array<HxCondDeclPrefix>;
};

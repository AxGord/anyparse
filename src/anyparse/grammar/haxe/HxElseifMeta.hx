package anyparse.grammar.haxe;

/**
 * One `#elseif <cond> <@:meta entries>` clause inside a
 * `HxConditionalMeta` chain. Metadata-scope twin of `HxElseifParam`:
 * the `#elseif` keyword commits the clause, the condition atom
 * follows, and the body is a try-parse Star of metadata entries
 * terminated by the next `#elseif` / `#else` / `#end` token.
 * Live dogfood shape: —
 * `#if mac @:cppFileCode('…') #elseif windows @:cppFileCode('…') #end`.
 */
@:peg
typedef HxElseifMeta = {
	@:kw('#elseif') var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing) var body: Array<HxMetadata>;
};

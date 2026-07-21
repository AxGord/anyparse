package anyparse.grammar.haxe;

/**
 * One `#elseif <cond> <modifier-prefix entries>` clause inside a
 * `HxConditionalMod` chain. Modifier-scope twin of `HxElseifMeta` /
 * `HxElseifHeritage`: the `#elseif` keyword commits the clause, the
 * condition atom follows, and the body is a try-parse Star of
 * `HxCondModPrefix` terminated by the next `#elseif` / `#else` /
 * `#end` token.
 *
 * No dogfood tree in the current corpus chains a modifier-prefix
 * region through `#elseif` - the shape exists for symmetry with the
 * metadata- and heritage-scope conditionals, so a hand-written
 * `#if a inline #elseif b extern #else @:extern #end` parses in every
 * arm rather than only in the first two.
 */
@:peg
typedef HxElseifMod = {
	@:kw('#elseif') var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing) var body: Array<HxCondModPrefix>;
};

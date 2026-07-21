package anyparse.grammar.haxe;

/**
 * One `#elseif <cond> <heritage clauses>` clause inside a
 * `HxConditionalHeritage` chain. Heritage-scope twin of
 * `HxElseifMeta` / `HxElseifMod`: the `#elseif` keyword commits the
 * clause, the condition atom follows, and the body is a try-parse Star
 * of `HxHeritageClause` terminated by the next `#elseif` / `#else` /
 * `#end` token.
 *
 * Live dogfood shape: openfl's `openfl.errors.Error` —
 * `class Error #if (haxe_ver >= "4.1.0") extends haxe.Exception
 *  #elseif (openfl_dynamic && haxe_ver < "4.0.0") implements Dynamic #end`.
 */
@:peg
typedef HxElseifHeritage = {
	@:kw('#elseif') var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing) var body: Array<HxHeritageClause>;
};

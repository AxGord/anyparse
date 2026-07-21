package anyparse.grammar.haxe;

/**
 * One `#elseif <cond> <expr>;` clause inside a `HxConditionalSemiExpr`
 * chain - the semicolon-terminated twin of `HxElseifExpr`, mirroring
 * `HxElseifType` at type scope.
 *
 * The `#elseif` keyword commits the clause on `cond`'s metadata
 * (`HxCatchClause` precedent), so the parent's `@:tryparse` Star loop
 * tries the kw at each iteration and terminates when the next token is
 * `#else` / `#end`.
 *
 * `@:trail(';')` mirrors the parent's MANDATORY per-branch terminator -
 * see `HxConditionalSemiExpr` for why it is mandatory rather than
 * `@:trailOpt`.
 *
 * Motivating source - `Pony/pony/net/http/HttpTools.hx:31`:
 *
 * ```haxe
 * public static var getJson:String->(Dynamic->Void)->Void =
 * #if nodejs
 * pony.net.http.platform.nodejs.HttpTools.getJson;
 * #elseif js
 * pony.net.http.platform.js.HttpTools.getJson;
 * #else
 * null;
 * #end
 * ```
 */
@:peg
typedef HxElseifSemiExpr = {
	@:kw('#elseif') var cond: HxPpCondLit;
	@:trail(';') var expr: HxExpr;
};

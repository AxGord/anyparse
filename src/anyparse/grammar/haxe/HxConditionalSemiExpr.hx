package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <expr>; [#elseif <cond> <expr>;]* [#else
 * <expr>;] #end` region whose branches terminate their value with a `;`
 * INSIDE the guard. Reached via `HxVarSemiInitRegion.Conditional`, which
 * owns the `=` and `#end` markers; the `#if` rides `cond`.
 *
 * Motivating source - `Pony/pony/net/http/HttpTools.hx:24` (the `=` sits
 * OUTSIDE the region and the `;` that terminates the field lives INSIDE
 * each branch):
 *
 * ```haxe
 * public static var get:String->(String->Void)->Void =
 * #if nodejs
 * pony.net.http.platform.nodejs.HttpTools.get;
 * #else
 * null;
 * #end
 * ```
 *
 * The bare-value spelling (`= #if nodejs A #else B #end;`) already
 * parsed through `HxVarDecl.init` -> `HxConditionalExpr`. This typedef is
 * the value-scope twin of `HxConditionalType`, which solved the same gap
 * for `typedef X = #if c A; #else B; #end` - same per-branch semicolon,
 * same `HxConditionalTypeElse`-style wrapper for the `#else` clause
 * (`@:trail` / `@:trailOpt` are both unusable on an `@:optional @:kw`
 * struct field, so the clause has to become its own non-optional
 * sub-typedef), same `elseifs`-before-`elseClause` ordering rule.
 *
 * The branch `;` is `@:trail(';')`, MANDATORY, where the type-scope twin
 * uses `@:trailOpt`. That is the discriminator this production runs on:
 * `HxClassMember.VarSemiCondInitMember` is tried BEFORE `VarMember`, so
 * an optional `;` made the ctor match the bare-value spelling too and
 * re-routed a shape that already parsed - the `;` after `#end` then fell
 * out as a stray `EmptySemiMember`. Requiring it means a region without
 * per-branch terminators fail-rewinds and reaches `VarMember` unchanged.
 *
 * WHY NOT `@:trailOpt(';')` ON `HxConditionalExpr` ITSELF:
 * `HxConditionalExpr` is reached by every expression-position `#if` in
 * the corpus, and its `elseExpr` carries three writer flags
 * (`padTrailing`, `captureSourceNewlineAfter`, `nestBodyOnSourceNewline`)
 * whose synth slots are keyed by field name. Wrapping that field in an
 * else-clause typedef - which the trailOpt-on-optional constraint forces
 * - would rename those slots and change the layout of every already-
 * parsing conditional expression.
 */
@:peg
typedef HxConditionalSemiExpr = {
	@:kw('#if') var cond: HxPpCondLit;
	@:trail(';') var expr: HxExpr;
	@:tryparse @:fmt(padLeading) var elseifs: Array<HxElseifSemiExpr>;
	@:optional @:kw('#else') var elseClause: Null<HxConditionalSemiExprElse>;
};

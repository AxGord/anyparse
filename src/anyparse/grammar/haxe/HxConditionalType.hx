package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <type>; [#elseif <cond> <type>;]* [#else
 * <type>;] #end` preprocessor-guarded type-position region. Type-scope
 * mirror of `HxConditionalExpr`: the enclosing `HxType.ConditionalType`
 * ctor consumes the `#if` keyword and the trailing `#end`; this typedef
 * covers the content between them — the condition atom, the then-branch
 * single type, an optional `#elseif` clause chain, and an optional
 * `#else` clause.
 *
 * Body is a single `HxType` (not a Star) because type-position `#if`
 * in real Haxe wraps exactly one type per branch — the canonical shape
 * is `typedef X = #if cond T1; #else T2; #end`, where each branch
 * contributes one type to the parent type position. Same Ref-vs-Star
 * divergence rationale as `HxConditionalExpr` (expr scope wraps one
 * value per branch).
 *
 * `type` carries `@:trailOpt(';')`: the corpus form
 * (`whitespace/issue_531_conditional_typedef`) puts a `;` after the
 * branch type before `#elseif` / `#else` / `#end`
 * (`typedef X = #if c A; #else B; #end`). The `;` is consumed, not
 * stored — the AST is identical to the no-semicolon form (the same
 * struct-field consume-not-store path as `HxIfExpr.thenBranch` /
 * `HxTryCatchExpr.body`; no `trailPresent` synth, so the writer
 * re-emits via the generic separator rather than source-faithfully —
 * the standard deferred-byte-reemit caveat). The host typedef's own
 * `;` stays optional via `HxDecl.TypedefDecl`'s `@:trailOpt(';')`, so
 * both the per-branch-`;` form and the `#if c A #else B #end;` form
 * parse.
 *
 * The `#else` clause is wrapped in `HxConditionalTypeElse` rather than
 * declared as `@:optional @:kw('#else') @:trailOpt(';') var elseType`:
 * `@:trailOpt` is dropped on `@:optional` fields (the struct-field
 * trailOpt parse block requires `!isOptional`), so an inline optional
 * `#else` type could not consume its trailing `;` and the outer
 * `@:trail('#end')` would fail on the leftover `;`. Moving the type
 * into a one-field sub-typedef makes that field non-optional, routing
 * its `;` through the supported trailOpt path while the `#else`
 * clause as a whole stays optional at this level (the standard
 * optional-kw-Ref engine path, target kind irrelevant — precedent
 * `HxExpr.ConditionalExpr` Refs the `HxConditionalExpr` typedef from
 * an enum the same way).
 *
 * `#elseif` chained-clause support (slice ω-cond-comp-elseif-type):
 * `elseifs: Array<HxElseifType>`, mirroring how `#elseif` landed for
 * the other scopes (`HxConditionalParam.elseifs`, `HxConditionalMeta.
 * elseifs`, `HxConditionalHeritage.elseifs`). Each `HxElseifType`
 * clause carries the `#elseif` keyword on its own `cond` field and a
 * single `HxType` body with the same `@:trailOpt(';')` shape as this
 * typedef's `type` field — the array-element struct does not need
 * `@:optional` for its trailOpt field to work, so the `@:trailOpt`-
 * dropped-on-`@:optional` constraint above does not apply to it. Field
 * order matters: `elseifs` MUST sit before `elseClause` so the
 * `#elseif` chain fully terminates before the optional `#else`
 * dispatch fires (same rule as every other conditional-compilation
 * scope's elseifs/elseBody pair). Motivating shape:
 * `typedef T = #if js A #elseif hl C #else B #end;`
 * (`haxe.ds.Vector` / `haxe.io.BytesInput` std-lib pattern).
 *
 * `init` is the optional `= <expr>` that a guarded type may drag along
 * when the region opens in a FIELD's type slot and closes past the
 * initializer (openfl `display/Preloader.hx:20`):
 *
 * ```haxe
 * public var onComplete:#if lime lime.app.Event<Void->Void> = new lime.app.Event<Void->Void>() #else Dynamic #end;
 * ```
 *
 * Exact mirror-image of `HxVarDecl.condInit` / `HxConditionalVarInit`,
 * which handles the case where the `#if` opens WHERE THE `=` WOULD BE
 * (`var x:Bool #if !js = false #end;`). There the type is outside the
 * guard and the assignment inside; here the type is inside the guard
 * and drags the assignment with it. The two slots are disjoint by
 * construction - `HxVarDecl` reaches this one through its `type` field
 * and that one through `condInit` - so a declaration can carry both.
 *
 * `@:optional @:lead('=')` (not a bare `@:lead`) so the optional-Ref
 * emit path supplies the ` = ` spacing: `=` is in neither
 * `HaxeFormat.spacedLeads` nor `tightLeads`, and the NON-optional lead
 * path emits tight. Same reasoning, same annotation, as
 * `HxConditionalVarInit.init`.
 *
 * `moreParams` carries whole FUNCTION PARAMETERS that follow the
 * guarded type inside the same region (openfl
 * `text/_internal/ShapeCache.hx:37`):
 *
 * ```haxe
 * getPositions:#if (js && html5) Void->Array<Float>, wordKey:String = null #else TextLayout #end
 * ```
 *
 * `HxParam.Conditional` already covers a `#if` that WRAPS whole
 * parameters; it cannot cover this one, because the region opens inside
 * a parameter's type and only then reaches the parameter boundary. The
 * run is led by the comma that terminates the host parameter, so it is
 * modelled as `HxCondTypeParamMore` elements each carrying their own
 * `@:lead(',')` - the `HxVarMore` shape - rather than a parent-level
 * `@:sep(',')`, which by definition sits BETWEEN elements and cannot
 * consume a leading one. See `HxCondTypeParamMore`.
 *
 * Field order is source order throughout: `type`, then the `= init` a
 * var-decl would put there, then the `, param` run a signature would
 * put there, then `elseifs`, then `elseClause`. `elseifs` before
 * `elseClause` is the hard constraint every cond-comp scope shares (the
 * `#elseif` chain must terminate before the `#else` dispatch fires);
 * the rest is convention, but keeping it means a reader can match the
 * struct against the source left to right.
 *
 * `elseifs` gained `@:trivia` in the same change and it is NOT
 * cosmetic. Referencing `HxExpr` from `init` promotes this struct into
 * trivia-bearing mode, and in that mode a non-`@:trivia` Star of a
 * paired element type fails to compile
 * (`HxElseifTypeT has no field newlineBefore`). The Star's runtime
 * behaviour with an empty `elseifs` is unchanged.
 */
@:peg
typedef HxConditionalType = {
	var cond: HxPpCondLit;
	@:trailOpt(';') var type: HxType;
	@:optional @:lead('=') var init: Null<HxExpr>;
	@:tryparse var moreParams: Array<HxCondTypeParamMore>;
	@:trivia @:tryparse @:fmt(padLeading) var elseifs: Array<HxElseifType>;
	@:optional @:kw('#else') var elseClause: Null<HxConditionalTypeElse>;
};

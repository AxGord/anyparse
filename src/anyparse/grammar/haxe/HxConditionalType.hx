package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <type>; [#elseif <cond> <type>;]* [#else <type>;] #end`
 * preprocessor-guarded type-position region. Type-scope mirror of `HxConditionalExpr`: the
 * enclosing `HxType.ConditionalType` ctor consumes the `#if` keyword and the trailing
 * `#end`; this typedef covers the content between them. The body is a single `HxType` (not
 * a Star) because a type-position `#if` wraps exactly one type per branch.
 *
 * `type` carries `@:trailOpt(';')`: the corpus form puts a `;` after the branch type before
 * `#elseif` / `#else` / `#end`. The `;` is consumed, not stored (the `HxIfExpr.thenBranch`
 * path). The host typedef's own `;` stays optional via `HxDecl.TypedefDecl`'s
 * `@:trailOpt(';')`, so both the per-branch-`;` form and `#if c A #else B #end;` parse.
 *
 * The `#else` clause is wrapped in `HxConditionalTypeElse` rather than declared as
 * `@:optional @:kw('#else') @:trailOpt(';') var elseType`: `@:trailOpt` is dropped on
 * `@:optional` fields, so an inline optional `#else` type could not consume its trailing
 * `;` and the outer `@:trail('#end')` would fail on it. A one-field sub-typedef makes that
 * field non-optional while the `#else` clause as a whole stays optional.
 *
 * `elseifs: Array<HxElseifType>` mirrors the other scopes: each clause carries the `#elseif`
 * keyword on its own `cond` field and a single `HxType` body with the same `@:trailOpt(';')`
 * (an array-element struct needs no `@:optional`). `elseifs` MUST sit before `elseClause` so
 * the chain terminates before the optional `#else` dispatch fires. It carries `@:trivia`
 * and that is NOT cosmetic: referencing `HxExpr` from `init` promotes this struct into
 * trivia-bearing mode, where a non-`@:trivia` Star of a paired element type fails to compile.
 *
 * `init` is the optional `= <expr>` a guarded type drags along when the region opens in a
 * FIELD's type slot and closes past the initializer (`var e:#if lime Event<Void->Void> =
 * new Event() #else Dynamic #end;`) — the mirror image of `HxVarDecl.condInit`, where the
 * `#if` opens WHERE THE `=` WOULD BE; the two slots are disjoint by construction.
 * `@:optional @:lead('=')` (not a bare `@:lead`) so the optional-Ref emit path supplies the
 * ` = ` spacing — the NON-optional lead path emits tight.
 *
 * `moreParams` carries whole FUNCTION PARAMETERS that follow the guarded type inside the
 * same region (`f:#if js Void->Array<Float>, key:String = null #else TextLayout #end`).
 * `HxParam.Conditional` cannot cover this, because the region opens inside a parameter's
 * type and only then reaches the parameter boundary; the run is led by the comma that
 * terminates the host parameter, so it is modelled as `HxCondTypeParamMore` elements each
 * carrying their own `@:lead(',')` (the `HxVarMore` shape) rather than a parent-level
 * `@:sep(',')`, which sits BETWEEN elements. Field order is source order.
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

package anyparse.grammar.haxe;

/**
 * Single declare-site type-parameter slot — `T`, `T:Constraint`, `T = Default`,
 * `T:Constraint = Default`. The wrapper exists so single-bound constraints, defaults and
 * multi-bound syntax (`<T:A & B>`) compose without reshaping the six declare-site
 * `typeParams` roots (`HxClassDecl`, `HxInterfaceDecl`, `HxAbstractDecl`, `HxEnumDecl`,
 * `HxTypedefDecl`, `HxFnDecl`).
 *
 * Shape: `meta* name (':' constraint ('&' more)*)? ('=' defaultValue)?`, mirroring `HxParamBody`. A leading metadata
 * run (`<@:const N>`) is the same `@:trivia @:tryparse` Star `HxVarDecl.meta` is, kept inline before the name; a comment
 * after the constraint's `:` or the default's `=` lands in that field's `AfterLead` slot (`@:fmt(captureAfterLead)`).
 * Fields:
 * `name:HxIdentLit`, an optional `@:lead(':')` `Ref` to `HxType` for the first constraint, a
 * bare `@:trivia @:tryparse` Star of `HxIntersectionClause` for the `& Type` tail
 * (structurally identical to `HxTypedefDecl.intersections` — `&` is scoped to this clause
 * rather than `HxType` for the reason given in `HxIntersectionClause`), and an optional
 * `@:lead('=')` `Ref` to `HxType` for the default. The `Ref` fields drive the same Case 5
 * emit path as `HxAnonFieldBody.type` and `HxParamBody.type`; the Star self-terminates when
 * the next token is not `&` (the `=` lead, the `,` outer sep or the `>` outer trail), so a
 * single- or no-constraint param adds no output.
 *
 * The deprecated Haxe 3 parenthesised multi-bound form `<T:(A, B)>` is a distinct construct
 * and stays a follow-up.
 *
 * The colon between name and constraint is spaced by `@:fmt(space('typeParamConstraintColon', 'lead'))` — `:` is
 * in `HaxeFormat.tightLeads`, so `None` emits `<T:Foo>`; an absent key makes the loader copy `typeHintColon` into it.
 * `=` spacing on the default is driven by `@:fmt(typeParamDefaultEquals)` (ω-typeparam-default-equals): the default
 * `WhitespacePolicy.Both` emits `<T = Int>`, matching haxe-formatter's `whitespace.binopPolicy`
 * default; `None` (or `whitespace.binopPolicy: "none"`) gives the tight `<T=Int>`.
 */
@:peg
typedef HxTypeParamDecl = {
	@:trivia
	@:tryparse
	@:fmt(metaLineEndInline)
	var meta: Array<HxMetadata>;
	@:fmt(inlineSep)
	var name: HxIdentLit;
	@:optional
	@:fmt(space('typeParamConstraintColon', 'lead'), captureAfterLead)
	@:lead(':')
	var constraint: Null<HxType>;
	@:trivia
	@:tryparse
	@:fmt(padLeading)
	var constraintMore: Array<HxIntersectionClause>;
	@:optional
	@:fmt(typeParamDefaultEquals, captureAfterLead)
	@:lead('=')
	var defaultValue: Null<HxType>;
}

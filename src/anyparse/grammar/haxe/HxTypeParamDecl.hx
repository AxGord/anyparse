package anyparse.grammar.haxe;

/**
 * Single declare-site type-parameter slot — `T`, `T:Constraint`,
 * `T = Default`, `T:Constraint = Default`.
 *
 * Wraps the bare-identifier form previously used directly in
 * `Array<HxIdentLit>` on every declare-site `typeParams` field
 * (`HxClassDecl`, `HxInterfaceDecl`, `HxAbstractDecl`, `HxEnumDecl`,
 * `HxTypedefDecl`, `HxFnDecl`). The wrapper exists so single-bound
 * constraints (`<T:Foo>`), defaults (`<T = Int>`), and multi-bound
 * syntax (`<T:A & B>`) compose without reshaping the six grammar
 * roots.
 *
 * Shape: `name (':' constraint ('&' more)*)? ('=' defaultValue)?`
 * mirroring `HxParamBody` — `name:HxIdentLit` followed by an optional
 * `@:lead(':')` `Ref` to `HxType` for the first constraint, then a
 * bare `@:trivia @:tryparse` Star of `HxIntersectionClause` for the
 * `& Type` tail of a multi-bound constraint (`<T:A & B & C>`),
 * structurally identical to `HxTypedefDecl.intersections` — `&` is
 * scoped to this clause rather than `HxType` for the reason given in
 * `HxIntersectionClause` (its header explicitly anticipates this
 * type-parameter-constraint use). Finally an optional `@:lead('=')`
 * `Ref` to `HxType` for the default. The `Ref` fields drive the same
 * Case 5 emit path that `HxAnonFieldBody.type` and `HxParamBody.type`
 * rely on; the `constraintMore` Star reuses the generic bare-tryparse
 * machinery, so no macro infra change is required. The Star
 * self-terminates when the next token is not `&` (the `=` default
 * lead, the `,` outer typeParams sep, or the `>` outer trail), so
 * common single/no-constraint type params add no output.
 *
 * The deprecated Haxe 3 parenthesised multi-bound form
 * `<T:(A, B)>` is a separate, distinct construct (not `&`-joined) and
 * remains a follow-up — it appears only in `#else` branches of
 * already-compounding corpus fixtures.
 *
 * The colon between name and constraint is emitted tight by default
 * (`<T:Foo>`, no surrounding spaces) — `:` is in `HaxeFormat.tightLeads`.
 * Writer-side `=` spacing on the default is driven by
 * `@:fmt(typeParamDefaultEquals)` (slice ω-typeparam-default-equals):
 * default `WhitespacePolicy.Both` emits `<T = Int>` / `<T:Foo = Bar>`
 * matching haxe-formatter's `whitespace.binopPolicy: @:default(Around)`.
 * Setting `typeParamDefaultEquals: WhitespacePolicy.None` (or loading
 * `whitespace.binopPolicy: "none"`) reverts to the tight `<T=Int>`
 * layout, matching the `_none` corpus variant.
 */
@:peg
typedef HxTypeParamDecl = {
	var name:HxIdentLit;
	@:optional @:lead(':') var constraint:Null<HxType>;
	@:trivia @:tryparse @:fmt(padLeading) var constraintMore:Array<HxIntersectionClause>;
	@:optional @:fmt(typeParamDefaultEquals) @:lead('=') var defaultValue:Null<HxType>;
}

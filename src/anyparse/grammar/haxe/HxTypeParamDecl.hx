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
 * syntax (`<T:A&B>`) compose without reshaping the six grammar roots —
 * multi-bound remains a follow-up slice that extends this typedef.
 *
 * Shape: `name (':' constraint)? ('=' defaultValue)?` mirroring
 * `HxParamBody` — `name:HxIdentLit` followed by an optional
 * `@:lead(':')` `Ref` to `HxType` for the constraint, then an optional
 * `@:lead('=')` `Ref` to `HxType` for the default. Both optional `Ref`
 * fields drive the same Case 5 emit path that `HxAnonFieldBody.type`
 * and `HxParamBody.type` rely on, so no macro infra change is
 * required.
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
	@:optional @:fmt(typeParamDefaultEquals) @:lead('=') var defaultValue:Null<HxType>;
}

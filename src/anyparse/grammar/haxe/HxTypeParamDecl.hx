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
 * The equals sign between name (or constraint) and default emits
 * with surrounding spaces (`<T = Int>`, `<T:Foo = Bar>`) via the
 * default optional-Ref non-tight-lead path — matching haxe-formatter's
 * effective output on `binopPolicy = around` (the default). The
 * `binopPolicy = none` corpus variant (`<T=Int>`) stays out of scope
 * for this slice; a knob can be added later as
 * `@:fmt(typeParamDefaultEquals)` if a fixture demands it.
 */
@:peg
typedef HxTypeParamDecl = {
	var name:HxIdentLit;
	@:optional @:lead(':') var constraint:Null<HxType>;
	@:optional @:lead('=') var defaultValue:Null<HxType>;
}

package anyparse.grammar.haxe;

/**
 * Single declare-site type-parameter slot — `T`, `T:Constraint`.
 *
 * Wraps the bare-identifier form previously used directly in
 * `Array<HxIdentLit>` on every declare-site `typeParams` field
 * (`HxClassDecl`, `HxInterfaceDecl`, `HxAbstractDecl`, `HxEnumDecl`,
 * `HxTypedefDecl`, `HxFnDecl`). The wrapper exists so single-bound
 * constraints (`<T:Foo>`) compose without reshaping the six grammar
 * roots — defaults (`<T = Int>`) and multi-bound syntax (`<T:A&B>`)
 * remain follow-up slices that extend this typedef.
 *
 * Shape: `name (':' constraint)?` mirroring `HxAnonFieldBody` —
 * `name:HxIdentLit` followed by an optional `@:lead(':')` `Ref` to
 * `HxType`. The `@:optional`/`@:lead` pair drives the same Case 5
 * emit path that `HxAnonFieldBody.type` and `HxParamBody.type` rely
 * on, so no macro infra change is required.
 *
 * The colon between name and constraint is emitted tight by default
 * (`<T:Foo>`, no surrounding spaces) — matching haxe-formatter's
 * effective output on the constraint corpus fixtures. A spacing knob
 * can be added later as `@:fmt(typeParamConstraintColon)` if a
 * fixture demands the around-form.
 */
@:peg
typedef HxTypeParamDecl = {
	var name:HxIdentLit;
	@:optional @:lead(':') var constraint:Null<HxType>;
}

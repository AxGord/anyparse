package anyparse.grammar.haxe;

/**
 * Body shape for a single function-parameter slot — the
 * `name : Type [= defaultValue]` portion shared by both the required
 * and optional branches of `HxParam`.
 *
 * Lifted out of the original `HxParam` typedef when the optional
 * marker `?name:Type` was added: the marker dispatches at the Alt-enum
 * level (`@:lead('?') Optional(body:HxParamBody)` vs the fallthrough
 * `Required(body:HxParamBody)`), and both branches share the same
 * name / type / default-value body without duplicating the field
 * declarations.
 *
 * `@:fmt(typeHintColon)` mirrors `HxVarDecl.type` / `HxAnonFieldBody.type` —
 * the colon emission flips between tight (`x:Int`) and around (`x : Int`)
 * per `HxModuleWriteOptions.typeHintColon`. The default-value lead
 * (`@:optional @:lead('=')`) reuses the same pattern as `HxVarDecl.init`.
 *
 * The `type` annotation is optional — `function f(x)`, `function f(?x)`,
 * `function f(x = 0)` all parse with no `:Type`. This is the exact
 * `HxVarDecl.type` shape (`@:optional @:lead(':') var type:Null<HxType>`):
 * the lead `:` is the commit point peeked by `matchLit`, and the
 * sub-rule parse only fires when the peek hits (D24). Both axes
 * (`@:optional` and `Null<HxType>`) are required by `ShapeBuilder` so
 * the grammar source documents optionality without a reader having to
 * cross-reference the meta list against the type (D23). Untyped
 * parameters are valid Haxe (the type is inferred); the sibling
 * `HxLambdaParam` was already untyped-tolerant, so untyped function-
 * declaration parameters now round-trip on the same footing.
 */
@:peg
typedef HxParamBody = {
	var name: HxIdentLit;
	@:optional @:fmt(typeHintColon) @:lead(':') var type: Null<HxType>;
	@:optional @:lead('=') var defaultValue: Null<HxExpr>;
}

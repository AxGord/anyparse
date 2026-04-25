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
 */
@:peg
typedef HxParamBody = {
	var name:HxIdentLit;
	@:fmt(typeHintColon) @:lead(':') var type:HxType;
	@:optional @:lead('=') var defaultValue:Null<HxExpr>;
}

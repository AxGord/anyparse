package anyparse.grammar.haxe;

/**
 * Body shape for a single anonymous-structure-type field — the
 * `name : Type` slot shared by both the required and optional
 * branches of `HxAnonField`.
 *
 * Lifted out of the original `HxAnonField` typedef when the optional
 * marker `?name:Type` was added: the marker dispatches at the Alt-enum
 * level (`@:lead('?') Optional(field:HxAnonFieldBody)` vs the
 * fallthrough `Required(field:HxAnonFieldBody)`), and both branches
 * share the same name-and-type body without duplicating the field
 * declarations.
 *
 * `@:fmt(typeHintColon)` mirrors `HxParam.type` / `HxVarDecl.type` —
 * the colon emission flips between tight (`x:Int`) and around
 * (`x : Int`) per `HxModuleWriteOptions.typeHintColon`.
 */
@:peg
typedef HxAnonFieldBody = {
	var name:HxIdentLit;
	@:fmt(typeHintColon) @:lead(':') var type:HxType;
}

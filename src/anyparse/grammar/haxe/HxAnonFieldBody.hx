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
 *
 * `@:queryTypeRef` on the `type` slot is what `HxParam.type` /
 * `HxVarDecl.type` deliberately do NOT carry: the default query
 * projection drops a type annotation, because the node that owns it
 * already names itself and `uses` / `blast` read the type-position
 * projection instead. An anonymous structure has no name of its own —
 * its identity IS its field names and their types — so without the tag
 * `{ xml:Xml, text:String }` and `{ xml:Int, text:Int }` rendered the
 * byte-identical `(Anon (Required xml) (Required text))`, and anything
 * keyed on that tree (`search`, `rewrite`, a deduplicating rule) merged
 * two different types. The tag routes the slot through the same
 * `_typeRefs` emit `parseFileTypeRefs` uses, so both projections agree
 * on the shape by construction.
 */
@:peg
typedef HxAnonFieldBody = {
	var name: HxIdentLit;
	@:fmt(typeHintColon) @:lead(':') @:queryTypeRef var type: HxType;
}

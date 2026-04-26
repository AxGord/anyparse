package anyparse.grammar.haxe;

/**
 * Body shape for the named-form arrow function parameter — the
 * `name : Type` slot inside a new-form arrow type
 * (`(name:Int, x:String) -> Bool`).
 *
 * Lifted into its own typedef when `HxArrowParam` was added so the
 * Alt-enum split between named and positional parameters can share the
 * Case 3 single-Ref-with-`@:lead(':')` lowering used by sibling
 * name-and-type bodies (`HxAnonFieldBody`, `HxParamBody`).
 *
 * Unlike `HxAnonFieldBody`, no `@:fmt(typeHintColon)` is wired on the
 * `:` lead — haxe-formatter has no separate knob for the colon inside
 * an arrow-type's named arg, and the corpus reference always emits
 * `name:Type` tight regardless of the type-hint policy elsewhere.
 */
@:peg
typedef HxArrowParamBody = {
	var name:HxIdentLit;
	@:lead(':') var type:HxType;
}

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
 * Unlike `HxAnonFieldBody`, the `:` lead reads a knob of its own, `arrowParamColon`
 * (`whitespace.arrowParamColonPolicy`), so the colon can be set apart from the annotations; an absent key
 * makes the loader copy `typeHintColon` into it.
 */
@:peg
typedef HxArrowParamBody = {
	var name: HxIdentLit;
	@:fmt(space('arrowParamColon', 'lead'))
	@:lead(':')
	var type: HxType;
}

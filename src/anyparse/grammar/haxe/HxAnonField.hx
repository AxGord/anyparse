package anyparse.grammar.haxe;

/**
 * Single field entry in an anonymous structure type: `name : Type`.
 *
 * Mirrors `HxObjectField` but in type position — the value is a full
 * `HxType`, recursively reachable so `{f:{f:Int}}` and `{cb:Int->Void}`
 * compose without revisiting the field shape.
 *
 * The optional-field marker `?name:Type` (used by `{?name:String}`)
 * is deferred to a follow-up slice; it requires either a Boolean
 * presence-flag field or an Alt enum split, and the four corpus
 * fixtures using it (issue_140, issue_642) need additional grammar
 * features (lambda `?param`, type-param constraints) before they pass
 * end-to-end.
 *
 * `@:fmt(typeHintColon)` mirrors `HxParam.type` / `HxVarDecl.type` —
 * the colon emission flips between tight (`x:Int`) and around
 * (`x : Int`) per `HxModuleWriteOptions.typeHintColon`. Fixture
 * `sameline/anon_type_hint_with_curly_next_and_space` exercises the
 * around variant.
 */
@:peg
typedef HxAnonField = {
	var name:HxIdentLit;
	@:fmt(typeHintColon) @:lead(':') var type:HxType;
}

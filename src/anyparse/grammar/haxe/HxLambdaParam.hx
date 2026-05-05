package anyparse.grammar.haxe;

/**
 * A single parameter in a lambda expression (`=>`) or anonymous
 * function expression (`function`).
 *
 * Shape: `name` or `name : Type`.
 *
 * Unlike `HxParam` (function declaration parameters), the type
 * annotation is optional — lambda parameters rely on type inference
 * when the annotation is omitted.  Default values are deferred.
 *
 * `@:fmt(typeHintColon)` mirrors `HxParamBody.type` / `HxVarDecl.type`
 * so the colon emission flips between tight (`x:Int`) and around
 * (`x : Int`) per `HxModuleWriteOptions.typeHintColon`. Required for
 * round-trip parity with `HxParamBody` once `HxFnExpr` becomes the
 * sole structural path for `@:overload(function(...)` metadata args.
 */
@:peg
typedef HxLambdaParam = {
	var name:HxIdentLit;
	@:optional @:fmt(typeHintColon) @:lead(':') var type:Null<HxType>;
}

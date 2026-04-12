package anyparse.grammar.haxe;

/**
 * Function declaration body for a class member `function`.
 *
 * Shape: `name ( params ) : ReturnType {}` where params is a
 * comma-separated list of `HxParam` entries (possibly empty).
 *
 * The `function` keyword lives on the enclosing `HxClassMember.FnMember`
 * constructor via `@:kw` — this typedef only describes the inside.
 *
 * The `params` field uses `@:lead('(') @:trail(')') @:sep(',')` which
 * selects the sep-peek termination mode in `emitStarFieldSteps`:
 * peek close-char for empty list, then sep-separated loop. Zero params
 * yields an empty array.
 *
 * Return type is mandatory with `@:lead(':')`. Optional return type
 * (type inference) is a future slice.
 *
 * Function bodies stay as the fixed literal `{}` via `@:trail('{}')`.
 * Real statement bodies are a future slice (η).
 */
@:peg
typedef HxFnDecl = {
	var name:HxIdentLit;
	@:lead('(') @:trail(')') @:sep(',') var params:Array<HxParam>;
	@:lead(':') @:trail('{}') var returnType:HxTypeRef;
}

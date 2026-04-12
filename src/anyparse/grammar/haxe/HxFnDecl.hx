package anyparse.grammar.haxe;

/**
 * Function declaration body for a class member `function`.
 *
 * Shape: `name ( params ) : ReturnType { body }` where params is a
 * comma-separated list of `HxParam` entries (possibly empty) and body
 * is zero or more statements inside braces.
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
 * The `body` field uses `@:lead('{') @:trail('}')` which selects the
 * close-peek termination mode in `emitStarFieldSteps` — same pattern
 * as `HxClassDecl.members`. Each `HxStatement` branch is
 * self-terminating via its own `;` trail, so no `@:sep` is needed.
 * Empty function bodies `{}` parse as an empty array.
 */
@:peg
typedef HxFnDecl = {
	var name:HxIdentLit;
	@:lead('(') @:trail(')') @:sep(',') var params:Array<HxParam>;
	@:lead(':') var returnType:HxTypeRef;
	@:lead('{') @:trail('}') var body:Array<HxStatement>;
}

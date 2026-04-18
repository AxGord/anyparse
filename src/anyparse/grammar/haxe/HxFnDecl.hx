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
 * Return type is `@:optional @:lead(':')` — when absent the function
 * relies on Haxe type inference. The lead `:` is the commit point for
 * the optional: `matchLit` peeks it, and the sub-rule parse only fires
 * when the peek hits (D24).
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
	@:lead('(') @:trail(')') @:sep(',') @:fmt(trailingComma('trailingCommaParams')) var params:Array<HxParam>;
	@:optional @:lead(':') var returnType:Null<HxTypeRef>;
	@:fmt(leftCurly) @:lead('{') @:trail('}') var body:Array<HxStatement>;
}

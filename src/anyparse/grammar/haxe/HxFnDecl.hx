package anyparse.grammar.haxe;

/**
 * Function declaration body for a class member `function`.
 *
 * Phase 3 slice: `fnName () : ReturnType {}` — the name followed by a
 * fixed empty parameter list `()`, a return-type annotation, and a
 * fixed empty body `{}`. Parameters, typed parameter lists, default
 * values, generic type parameters, function bodies with statements,
 * and modifiers (`public`, `override`, `static`, …) are all out of
 * scope for this session.
 *
 * Whitespace between the tokens is allowed (the generated parser
 * skips `@:ws` before each literal), but *inside* the fixed pairs
 * `()` and `{}` there can be no characters — the literal pairs are
 * matched exactly as `"()"` and `"{}"`. A future milestone will turn
 * these into real sub-rules carrying parameters and statements.
 *
 * The `function` keyword lives on the enclosing `HxClassMember.FnMember`
 * constructor via `@:kw` — this typedef only describes the inside.
 */
@:peg
typedef HxFnDecl = {
	@:trail('()') var name:HxIdentLit;
	@:lead(':') @:trail('{}') var returnType:HxTypeRef;
}

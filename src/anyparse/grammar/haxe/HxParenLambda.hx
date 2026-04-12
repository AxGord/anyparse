package anyparse.grammar.haxe;

/**
 * Parenthesised lambda expression: `(params) => body`.
 *
 * The parameter list follows the same `@:lead('(') @:trail(')')
 * @:sep(',')` Star-struct pattern as `HxFnDecl.params`, but uses
 * `HxLambdaParam` (optional type) instead of `HxParam` (mandatory
 * type).  Empty parameter lists (`() => expr`) are handled by the
 * sep-peek close-char guard — the loop sees `)` before trying to
 * parse the first element.
 *
 * The body is a full `HxExpr` preceded by the `=>` literal.
 * `@:lead('=>')` emits `expectLit(ctx, '=>')` — if the arrow is
 * absent (e.g. a plain `ParenExpr`), the expectation throws and
 * `tryBranch` rolls back to the next atom candidate.
 */
@:peg
typedef HxParenLambda = {
	@:lead('(') @:trail(')') @:sep(',') var params:Array<HxLambdaParam>;
	@:lead('=>') var body:HxExpr;
}

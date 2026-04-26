package anyparse.grammar.haxe;

/**
 * Parenthesised arrow-lambda expression with `->` body separator:
 * `(params) -> body`. The canonical Haxe lambda syntax.
 *
 * Structurally identical to `HxParenLambda` (the `=>` form retained
 * for map-entry-style lambdas in pre-existing test data) — same
 * `(params) lead/trail/sep` Star pattern over `HxLambdaParam`, same
 * trailing-comma policy, same `@:lead('->')` body commit point.
 *
 * Placed before `HxParenLambda` in `HxExpr` atom order so `tryBranch`
 * tries the canonical `->` form first; non-arrow inputs fall through
 * to the legacy `=>` form, then to `ParenExpr`.
 *
 * `@:fmt(arrowFunctions)` on `body` gates the spacing around the `->`
 * separator on `opt.arrowFunctions:WhitespacePolicy`. Default `Both`
 * matches haxe-formatter's `whitespace.arrowFunctionsPolicy:
 * @:default(Around)` — emits `(params) -> body`. Setting the runtime
 * policy to `None` produces the tight `(params)->body` shape. Sibling
 * to `@:fmt(functionTypeHaxe4)` on `HxArrowFnType.ret` (the type-
 * position `(args) -> ret`); the two knobs are independent so a config
 * can space the type form while keeping the expression form tight, or
 * vice versa, mirroring upstream's separate JSON keys. The single-
 * ident infix form `arg -> body` (`HxExpr.ThinArrow`) is on the Pratt
 * infix path which already emits ` -> ` with surrounding spaces by
 * default and is unaffected by this knob.
 */
@:peg
typedef HxThinParenLambda = {
	@:lead('(') @:trail(')') @:sep(',') @:fmt(trailingComma('trailingCommaParams')) var params:Array<HxLambdaParam>;
	@:fmt(arrowFunctions) @:lead('->') var body:HxExpr;
}

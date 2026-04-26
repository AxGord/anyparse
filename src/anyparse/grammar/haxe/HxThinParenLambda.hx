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
 */
@:peg
typedef HxThinParenLambda = {
	@:lead('(') @:trail(')') @:sep(',') @:fmt(trailingComma('trailingCommaParams')) var params:Array<HxLambdaParam>;
	@:lead('->') var body:HxExpr;
}

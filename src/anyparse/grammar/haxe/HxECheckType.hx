package anyparse.grammar.haxe;

/**
 * Type-check expression payload — `(expr : Type)`.
 *
 * Shape: `(expr, type)` separated by `:`.
 *
 * The two-`Ref` field-pair pattern mirrors `HxTypedCast` (`(target,
 * type)`): first field carries `@:lead('(')`, second field carries
 * `@:lead(':') @:trail(')')`. The differences are the inner separator
 * (`:` instead of `,`) and the writer-side spacing knob — `@:fmt(typeCheckColon)`
 * routes `:` through `opt.typeCheckColon:WhitespacePolicy`, defaulting
 * to `Both` so `("" : String)` round-trips with surrounding spaces. This
 * matches haxe-formatter's `whitespace.typeCheckColonPolicy: @:default(Around)`.
 *
 * The wrapping atom ctor (`ECheckTypeExpr` in `HxExpr`) is placed
 * BEFORE both `ParenExpr` and `ParenLambdaExpr` so a typed map key
 * `(x : Int) => body` parses as this check-type atom + prec-0 infix
 * `=>` (`Arrow(ECheckType, body)`, matching haxe-formatter's
 * `Binop(OpArrow, ECheckType(...), body)`), and bare `(expr)` falls
 * through to `ParenExpr` after `tryBranch` rolls back the missing `:`.
 */
@:peg
typedef HxECheckType = {
	@:lead('(') var expr: HxExpr;
	@:fmt(typeCheckColon) @:lead(':') @:trail(')') var type: HxType;
};

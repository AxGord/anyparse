package anyparse.grammar.haxe;

/**
 * Typed-cast expression payload — `cast(expr, Type)`.
 *
 * Shape: `(target, type)`.
 *
 * The `cast` keyword is consumed at the enum-branch level
 * (`@:kw('cast')` on the `TypedCastExpr` ctor in `HxExpr`). This typedef
 * describes the remainder: an opening paren, an expression, a comma,
 * a type, and a closing paren. Same field-pair pattern as
 * `HxCatchClause` (`catch (name:Type)`): two `Ref` fields, first with
 * `@:lead('(')`, second with `@:lead(',')` and `@:trail(')')`.
 *
 * The bare untyped form `cast x` is the separate `CastExpr(operand)`
 * ctor in `HxExpr`. Source order in the enum tries `TypedCastExpr`
 * first; the `tryBranch` rollback in `Lowering` reverts the `cast`
 * keyword and `(` consumption when the comma is absent (`cast (x)` /
 * `cast x`), and the bare `CastExpr` branch picks up the operand.
 */
@:peg
typedef HxTypedCast = {
	@:lead('(') var target:HxExpr;
	@:lead(',') @:trail(')') var type:HxType;
};

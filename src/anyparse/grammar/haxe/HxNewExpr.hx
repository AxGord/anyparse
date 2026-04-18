package anyparse.grammar.haxe;

/**
 * Grammar for `new T(args)` constructor call expressions.
 *
 * Shape: `new ClassName(arg1, arg2, ...)`.
 *
 * The `new` keyword is consumed at the enum-branch level (`@:kw('new')`
 * on the `NewExpr` ctor in `HxExpr`). This typedef describes the
 * remainder: a type name (bare identifier) followed by a parenthesised,
 * comma-separated argument list.
 *
 * The argument list reuses the sep-peek Star field pattern — same as
 * function parameters in `HxFnDecl` and call args in
 * `HxExpr.Call`. Zero Lowering changes.
 */
@:peg
typedef HxNewExpr = {
	var type:HxIdentLit;
	@:lead('(') @:trail(')') @:sep(',') @:fmt(trailingComma('trailingCommaArgs')) var args:Array<HxExpr>;
};

package anyparse.grammar.haxe;

/**
 * `#else <expr>;` clause of a `HxConditionalSemiExpr` region.
 *
 * Exists as its own one-field typedef for the same reason
 * `HxConditionalTypeElse` does: a terminator literal cannot ride an
 * `@:optional @:kw(...)` struct field - `@:trailOpt` is dropped there
 * (the struct-field trailOpt parse block requires `!isOptional`) and
 * `@:trail` is rejected outright by the codegen. An inline
 * `@:optional @:kw('#else') var elseExpr` could therefore not consume its
 * branch terminator, and the region's outer `@:trail('#end')` would fail
 * on the leftover `;`. Moving the expression into a sub-typedef makes
 * that field non-optional and routes its `;` through the supported path,
 * while the `#else` clause as a whole stays optional at the parent level.
 */
@:peg
typedef HxConditionalSemiExprElse = {
	@:trail(';') var expr: HxExpr;
};

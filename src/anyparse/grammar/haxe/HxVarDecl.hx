package anyparse.grammar.haxe;

/**
 * Variable declaration body for a class member `var`.
 *
 * Phase 3 slice: name, an optional type annotation prefixed by `:`,
 * and an optional initializer prefixed by `=`. Either, both, or neither
 * may be present — `var x;`, `var x:Int;`, `var x = 1;`, `var x:Int = 1;`
 * all parse. The initializer, when present, is a single `HxExpr` atom
 * (int / bool / null / identifier) — operators, calls, and field access
 * come with the Pratt slice.
 *
 * Modifiers (`public`, `private`, `static`, …), property accessors
 * (`(default, null)`), and default values are out of scope for this
 * session.
 *
 * The `var` keyword itself and the trailing `;` live on the enclosing
 * `HxClassMember.VarMember` constructor via `@:kw` / `@:trail` — this
 * typedef only describes the inside.
 *
 * The `init` field is marked both `@:optional` and `Null<HxExpr>`:
 * both axes are required by `ShapeBuilder` so the grammar source
 * documents optionality without forcing a reader to cross-reference
 * the type and the meta list (D23). The `@:lead('=')` is the commit
 * point for the optional — `matchLit` peeks it, and the sub-rule
 * parse only fires when the peek hits (D24).
 */
@:peg
typedef HxVarDecl = {
	var name:HxIdentLit;
	@:optional @:fmt(typeHintColon) @:lead(':') var type:Null<HxTypeRef>;
	@:optional @:lead('=') var init:Null<HxExpr>;
}

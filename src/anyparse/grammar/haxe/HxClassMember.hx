package anyparse.grammar.haxe;

/**
 * A class member in the Phase 3 skeleton grammar.
 *
 * Three forms are recognised:
 *  - `VarMember` — `var name:Type;` — a plain mutable field
 *    declaration with a mandatory type annotation and a trailing
 *    semicolon.
 *  - `FinalMember` — `final name:Type = init;` — an immutable field
 *    declaration. The body shape is identical to `VarMember`'s
 *    (`HxVarDecl` covers optional `:Type` and optional `= init`), the
 *    only difference is `@:kw('final')` instead of `@:kw('var')`.
 *    Mirrors `HxStatement.FinalStmt` at the statement level.
 *  - `FnMember`  — `function name():ReturnType {}` — a function
 *    declaration with fixed empty parameter list and empty body (see
 *    `HxFnDecl` for the current limitations).
 *
 * Each constructor uses `@:kw` for its introducer keyword (`var`,
 * `final`, `function`) so the generated parser enforces a word
 * boundary on the match and `classy` does not look like a truncated
 * `class`, `finalists` does not look like `final` followed by `ists`.
 * The trailing `;` on `VarMember` and `FinalMember` is a
 * per-constructor `@:trail` that the macro emits after the sub-rule
 * value is parsed.
 *
 * `final` reaching this enum (instead of being consumed as a member
 * modifier) is enabled by `HxMemberDecl.modifiers` carrying
 * `Array<HxMemberModifier>` — the modifier enum without `Final`. The
 * sealed-class top-level form `final class Foo {}` keeps `Final` via
 * the broader `HxModifier` enum on `HxTopLevelDecl.modifiers`. The
 * legacy `final var x:Int;` form (modifier on `var`) is consequently
 * not accepted at the member position; modern `final x:Int;` is the
 * idiomatic spelling.
 */
@:peg
enum HxClassMember {

	@:kw('var') @:trail(';')
	VarMember(decl:HxVarDecl);

	@:kw('final') @:trail(';')
	FinalMember(decl:HxVarDecl);

	@:kw('function')
	FnMember(decl:HxFnDecl);
}

package anyparse.grammar.haxe;

/**
 * A class member in the Phase 3 skeleton grammar.
 *
 * Two forms are recognised:
 *  - `VarMember` — `var name:Type;` — a plain field declaration with
 *    a mandatory type annotation and a trailing semicolon.
 *  - `FnMember`  — `function name():ReturnType {}` — a function
 *    declaration with fixed empty parameter list and empty body (see
 *    `HxFnDecl` for the current limitations).
 *
 * Each constructor uses `@:kw` for its introducer keyword (`var`,
 * `function`) so the generated parser enforces a word boundary on the
 * match and `classy` does not look like a truncated `class`. The
 * trailing `;` on `VarMember` is a per-constructor `@:trail` that the
 * macro emits after the sub-rule value is parsed.
 *
 * **Note on member-level `final`**: bare `final x = 1;` (immutable
 * field) is not parsed here. `HxModifier` lists `final` as a modifier
 * (correctly — `final class`, `final function f()`, `final var x` all
 * exist), and the `HxMemberDecl` modifier Star greedily consumes it
 * before this enum dispatches. Adding a `FinalMember(HxVarDecl)` ctor
 * would never be reached. Disambiguation needs lookahead in the
 * modifier Star — separate slice. Statement-level `final` (in function
 * bodies) is unaffected and parses via `HxStatement.FinalStmt`.
 */
@:peg
enum HxClassMember {

	@:kw('var') @:trail(';')
	VarMember(decl:HxVarDecl);

	@:kw('function')
	FnMember(decl:HxFnDecl);
}

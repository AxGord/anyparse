package anyparse.grammar.haxe;

/**
 * Body of a top-level `final …` declaration (slice ω-module-final),
 * dispatched after the enclosing `HxDecl.FinalDecl` ctor consumes the
 * `final` keyword. `final` is ambiguous at the module/type-decl scope:
 *
 *   - `final class Foo {}`  — the sealed-class marker, a modifier on a
 *     following `class` declaration; and
 *   - `final FOO = 1;`      — a module-level immutable binding.
 *
 * The grammar deliberately carries no lookahead (see `HxMemberModifier`:
 * member-scope `final` was disambiguated by an enum split "without
 * lookahead in the Lit strategy"). At top level `final` cannot simply be
 * dropped from the modifier set the way `HxMemberModifier` drops it —
 * `final class` is a real production — so the two forms are separated
 * here by an ordered first-match dispatch with `tryBranch` rollback,
 * exactly the shared-keyword pattern used by `HxDecl`'s
 * `EnumAbstractDecl` → `EnumDecl` fallthrough:
 *
 *   - `ClassForm` is tried first. `HxClassDecl` opens with
 *     `@:kw('class')` (word-boundary enforced), so `final class Foo {}`
 *     matches and `final FOO = 1;` / `final classy = 1;` fail the
 *     `class` keyword immediately.
 *   - On that failure `tryBranch` restores `ctx.pos` and dispatch falls
 *     through to `VarForm`, which reuses `HxVarDecl` verbatim — the same
 *     keyword-agnostic body the `var`/`final` member ctors and
 *     `HxDecl.VarDecl` already use (its doc states the introducer
 *     keyword and trailing `;` live on the enclosing ctor).
 *
 * The enclosing `HxDecl.FinalDecl` carries `@:kw('final')` and
 * `@:trailOpt(';')`: the optional `;` terminates the `VarForm` binding
 * (`final FOO = 1;`) and is harmlessly absent for the `}`-terminated
 * `ClassForm`.
 */
@:peg
enum HxFinalDecl {

	@:fmt(multilineCtor)
	ClassForm(decl: HxClassDecl);

	VarForm(decl: HxVarDecl);

}

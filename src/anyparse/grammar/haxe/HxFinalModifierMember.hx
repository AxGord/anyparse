package anyparse.grammar.haxe;

/**
 * Body of a member declaration whose `final` keyword is a non-overridable METHOD MODIFIER
 * rather than the introducer of an immutable field — dispatched after the enclosing
 * `HxClassMember.FinalModifiedMember` ctor consumes the `final` keyword.
 *
 * `final` is ambiguous at the member position, exactly the way it is at the top-level decl
 * position (see `HxFinalDecl`): `final foo:Int = 1;` is an immutable FIELD declaration,
 * handled by `HxClassMember.FinalMember(HxVarDecl)`; `final static function main()` is a
 * non-overridable method MODIFIER preceding further modifiers and the `function` keyword,
 * handled here. `final` as a modifier is METHOD-ONLY in Haxe, so this typedef requires the
 * `function` keyword after the optional modifier run; the legacy `final var x:Int;` form is
 * consequently still rejected (it falls through `FnDecl`'s `function` dispatch, then through
 * `FinalMember`'s name match on the `var` reserved keyword).
 *
 * The grammar carries no lookahead (the load-bearing reason `Final` was split out of
 * `HxMemberModifier` / `HxModifier` — a greedy modifier Star would eat the `final` of `final
 * foo:Int;` and then fail dispatch). The two forms are therefore separated by an ordered
 * first-match dispatch with `tryBranch` rollback at the `HxClassMember` enum level: the
 * modifier form (`FinalModifiedMember`) is tried FIRST, and for a plain `final foo:Int;` the
 * modifier run is empty and the mandatory `@:kw('function')` fails on the field name `foo`,
 * `tryBranch` restores `ctx.pos`, and dispatch falls through to `FinalMember` — the analog
 * of `HxFinalDecl`'s `ClassForm` → `VarForm` fallthrough.
 *
 * The shape is a tight Seq of the remaining modifier run plus the function declaration —
 * leading metadata is NOT re-accepted after `final` (it precedes `final` in source via
 * `HxMemberDecl.meta`). The `modifiers` Star is the byte twin of `HxMemberDecl.modifiers`
 * (`@:trivia @:tryparse @:fmt(forceInlineSep)`); the `function` keyword + body reuse
 * `HxFnDecl` verbatim, and the function block `}` is self-terminating, so this typedef
 * carries no terminator of its own. Reachable shapes: `final function f() {}`, `final static
 * function f() {}`, `final inline function f() {}`.
 *
 * The writer reassembles the source by emitting the consumed `final` keyword (from the
 * `@:kw('final')` on `FinalModifiedMember`) followed by the modifier run, the `function`
 * keyword and the body — one member, so the inter-member blank-line model sees a single
 * member, not a bogus `final <name>` field split off the preceding one.
 */
@:peg
typedef HxFinalModifierMember = {
	@:trivia @:tryparse @:fmt(forceInlineSep) var modifiers: Array<HxMemberModifier>;
	@:kw('function') var fn: HxFnDecl;
}

package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <members> [#elseif …] [#else <members>] #end`
 * preprocessor-guarded region wrapping whole class/interface/abstract
 * member declarations. The member-scope twin of `HxConditionalStmt` /
 * `HxConditionalDecl`: the enclosing `HxClassMember.Conditional` ctor
 * consumes the `#if` keyword and the trailing `#end`; this typedef
 * covers the content between them — the condition atom, the then-body
 * Star of further members, an optional `#elseif` clause chain, and an
 * optional `#else` clause with its own member Star.
 *
 * This is distinct from `HxMemberModifier.Conditional(HxConditionalMod)`,
 * which guards a run of access/storage MODIFIERS (`#if X public #end
 * function f()`). Member scope wraps the WHOLE member declaration
 * (`#if X private function f() {} #end`). At a member position the
 * modifier-scope ctor is tried first via the modifiers Star; its
 * `@:trail('#end')` fails on the member introducer keyword (`function`,
 * `var`, `final`), `tryBranch` rolls back, and `HxClassMember` then
 * dispatches here on `#if` — the same shared-keyword rollback pattern
 * as `PackageDecl` to `PackageEmpty`.
 *
 * Element type is `HxMemberDecl` (not bare `HxClassMember`) so leading
 * metadata + modifiers inside the conditional region parse uniformly
 * through the same meta + modifier Stars used by `HxClassDecl.members`.
 * The body's `@:tryparse` Star terminates after at least one member
 * when the next token is not a recognised member start — `#elseif`,
 * `#else`, and `#end` fail every meta + modifier + member-keyword
 * dispatch path, so the loop stops there.
 *
 * Known limitation, shared verbatim with the decl-scope precedent: an
 * EMPTY body (`#if cond #end` with zero members) is rejected, not
 * accepted as a zero-element Star. `HxMemberDecl`'s empty meta +
 * modifier prefix Stars consume nothing, then the mandatory
 * `member:HxClassMember` field throws on the terminator before the
 * tryparse Star can roll back to zero elements. `HxConditionalDecl`
 * behaves identically (`#if sys\n#end` at module scope throws
 * `expected HxDecl`); member scope mirrors it rather than diverging.
 * No real-world source has an empty conditional member body. Lifting
 * this is a core Lowering tryparse-Star-of-struct rollback change
 * spanning decl + stmt + member scopes, out of scope for the
 * member-scope twin slice.
 *
 * Nested `#if` is supported transitively because the body re-enters
 * `HxClassMember.Conditional` through `HxMemberDecl`.
 *
 * Body / elseBody flags are deliberately the minimal
 * `@:trivia @:tryparse @:fmt(padLeading, padTrailing)` shape (mirror of
 * `HxConditionalStmt`). The decl-scope import/using blank-line cascades
 * on `HxConditionalDecl.body` are NOT mirrored: members carry their own
 * blank-line model (`interMemberBlankLines`, applied by
 * `HxClassDecl.members`); an import-ordering cascade has no meaning at
 * member scope. Add a member blank-line cascade only if a concrete
 * corpus fixture later demands it.
 *
 * `@:optional @:kw('#else') @:tryparse var elseBody` uses the kw-led
 * optional Star path (`Lowering.emitOptionalKwStarFieldSteps`): `#else`
 * is the commit point, a miss leaves the field `null` so the writer
 * skips the entire clause.
 */
@:peg
typedef HxConditionalMember = {
	var cond:HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing) var body:Array<HxMemberDecl>;
	@:trivia @:tryparse var elseifs:Array<HxElseifMember>;
	@:optional @:kw('#else') @:trivia @:tryparse @:fmt(padLeading, padTrailing) var elseBody:Null<Array<HxMemberDecl>>;
};

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
 * An EMPTY body parses, and this Star was never what stood in its way: it
 * DOES roll back to zero elements, which `#if a #else var x; #end` — an
 * empty then-body, parsed since the slice shipped — has always proved. What
 * rejected `#if cond #end` sat one level up. `HxMemberDecl.meta` claims the
 * whole region (`HxMetadata.Conditional` takes an empty body), so the region
 * becomes a member PREFIX exactly as in `#if a #end var b:Int;`, and the
 * mandatory `member` field was then left facing the class-body `}`. `member`
 * is now `@:optional @:absentOn` on that `}`, so a member declaration that is
 * nothing but its own prefix is legal — and the empty-region shape therefore
 * lands in `meta`, not in this typedef.
 *
 * Module scope is NOT fixed and is not the same fix: `HxTopLevelDecl.decl`
 * has the identical mandatory-field shape, but its terminator is EOF, which
 * `@:absentOn` has no literal to peek — `class C {}` followed by a trailing
 * `#if sys` / `#end` still throws.
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
	var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing, conditionalBodyIndent) var body: Array<HxMemberDecl>;
	@:trivia @:tryparse @:fmt(elemSelfTrailsNewline) var elseifs: Array<HxElseifMember>;
	@:optional @:kw('#else') @:trivia @:tryparse @:fmt(padLeading, padTrailing, conditionalBodyIndent) var elseBody: Null<Array<HxMemberDecl>>;
};

package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <members> [#elseif …] [#else <members>] #end` preprocessor-guarded
 * region wrapping whole class/interface/abstract member declarations — the member-scope twin
 * of `HxConditionalStmt` / `HxConditionalDecl`. The enclosing `HxClassMember.Conditional`
 * ctor consumes the `#if` keyword and the trailing `#end`; this typedef covers the content
 * between them — the condition atom, the then-body Star of further members, an optional
 * `#elseif` clause chain, and an optional `#else` clause with its own member Star.
 *
 * Distinct from `HxMemberModifier.Conditional(HxConditionalMod)`, which guards a run of
 * access/storage MODIFIERS (`#if X public #end function f()`); member scope wraps the WHOLE
 * member declaration (`#if X private function f() {} #end`). At a member position the
 * modifier-scope ctor is tried first via the modifiers Star; its `@:trail('#end')` fails on
 * the member introducer keyword, `tryBranch` rolls back, and `HxClassMember` then dispatches
 * here on `#if` — the same shared-keyword rollback pattern as `PackageDecl` to
 * `PackageEmpty`.
 *
 * Element type is `HxMemberDecl` (not bare `HxClassMember`) so leading metadata + modifiers
 * inside the region parse uniformly through the same meta + modifier Stars
 * `HxClassDecl.members` uses. The body's `@:tryparse` Star terminates when the next token is
 * not a recognised member start — `#elseif`, `#else` and `#end` fail every meta + modifier +
 * member-keyword dispatch path — and it DOES roll back to zero elements (`#if a #else var x;
 * #end`). An empty region `#if cond #end` never lands here at all: `HxMemberDecl.meta` claims
 * it (`HxMetadata.Conditional` takes an empty body), so it becomes a member PREFIX exactly as
 * in `#if a #end var b:Int;`, and `HxMemberDecl.member` is `@:optional @:absentOn('}')` so a
 * member that is nothing but its own prefix is legal. Nested `#if` is supported transitively
 * because the body re-enters `HxClassMember.Conditional` through `HxMemberDecl`.
 *
 * Body / elseBody flags are the minimal `@:trivia @:tryparse @:fmt(padLeading, padTrailing)`
 * shape (mirror of `HxConditionalStmt`). The decl-scope import/using blank-line cascades on
 * `HxConditionalDecl.body` are NOT mirrored: members carry their own blank-line model
 * (`interMemberBlankLines`, applied by `HxClassDecl.members`), and an import-ordering cascade
 * has no meaning at member scope.
 *
 * `@:optional @:kw('#else') @:tryparse var elseBody` uses the kw-led optional Star path
 * (`StarFieldLowering.emitOptionalKwStarFieldSteps`): `#else` is the commit point, and a miss
 * leaves the field `null` so the writer skips the entire clause.
 */
@:peg
typedef HxConditionalMember = {
	var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing, conditionalBodyIndent) var body: Array<HxMemberDecl>;
	@:trivia @:tryparse @:fmt(elemSelfTrailsNewline) var elseifs: Array<HxElseifMember>;
	@:optional @:kw('#else') @:trivia @:tryparse @:fmt(padLeading, padTrailing, conditionalBodyIndent) var elseBody: Null<Array<HxMemberDecl>>;
};

package anyparse.grammar.haxe;

/**
 * Access and storage modifiers for class / interface / abstract members. Mirror of
 * `HxModifier` minus `Final` — at the member position `final` introduces a
 * `HxClassMember.FinalMember(HxVarDecl)` field declaration (modern `final x:Int;`), not a
 * modifier on a following `var`/`function`; splitting the enum off its top-level sibling
 * lets the modifier Star yield to `HxClassMember`'s `@:kw('final')` dispatch without
 * lookahead in the Lit strategy. Top-level uses (`final class Foo {}`) keep the full
 * `HxModifier` enum via `HxTopLevelDecl.modifiers`, where `Final` IS a modifier.
 *
 * The legacy `class A { final var x:Int; }` syntax is consequently rejected — the modern
 * `final x:Int;` form supersedes it, matching Haxe 4+ idiom. It is rejected inside a
 * `#if ... #end` guard too: `HxCondModPrefix`, the element type of a conditional modifier
 * region, omits `Final` as well (deferred there rather than deprecated — see that enum).
 *
 * `Abstract` is the abstract-member modifier. `HxCondModPrefix` omits it too: in the
 * `#if (haxe_ver >= 4.2) abstract #end class X` shape the keyword introduces an abstract
 * CLASS, which is decl dispatch (`HxDecl.AbstractClassDecl`), not a member modifier, so
 * admitting it here would not be the same capability.
 *
 * `Macro` is the macro-function modifier (`macro function f()`). It is member-position only
 * and deliberately absent from `HxModifier` — `macro class` is not valid Haxe. The
 * expression-position `macro {...}` reification keyword is a separate grammar concern: the
 * modifier Star only runs at member-declaration start. `HxCondModPrefix` does carry `Macro`,
 * because a guarded region reached from either scope may splice it (`public static #if
 * !macro macro #end function includeFile(...)` in the standard library); `HxCondModPrefix`
 * is shared by both scopes' `Conditional` ctors, so INSIDE a guard the `HxModifier` /
 * `HxMemberModifier` split is not enforced — permissiveness only, consistent with semantic
 * validation not being the parser's job.
 *
 * Keyword-only branches are zero-arg. The generated parser enforces word boundaries via
 * `expectKw` so `publicly` does not partially match `public`.
 *
 * The `Conditional` branch covers `#if <cond> <entries> [#elseif ...] [#else ...] #end`
 * regions interleaved with real modifiers. Its inner body uses `HxCondModPrefix` via
 * `HxConditionalMod` — a widened element type that admits metadata tags and the bare `enum`
 * / `macro` keywords alongside the plain modifier keywords, so a branch straddling the
 * modifier/metadata boundary (`#if (haxe_ver >= 4.2) extern #else @:extern #end`) parses as
 * one region.
 */
@:peg
enum HxMemberModifier {

	@:kw('public') Public;
	@:kw('private') Private;
	@:kw('static') Static;
	@:kw('inline') Inline;
	@:kw('override') Override;
	@:kw('dynamic') Dynamic;
	@:kw('extern') Extern;
	@:kw('macro') Macro;
	@:kw('abstract') Abstract;
	@:kw('overload') Overload;

	@:kw('#if') @:trail('#end')
	Conditional(inner: HxConditionalMod);

}

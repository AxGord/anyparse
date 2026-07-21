package anyparse.grammar.haxe;

/**
 * Access and storage modifiers for class / interface / abstract
 * members. Mirror of `HxModifier` minus `Final` - at the member
 * position `final` introduces a `HxClassMember.FinalMember(HxVarDecl)`
 * field declaration (modern Haxe `final x:Int;` immutable field), not
 * a modifier on a following `var`/`function`. Splitting the enum off
 * its top-level sibling lets the modifier Star yield to
 * `HxClassMember`'s `@:kw('final')` dispatch without lookahead in the
 * Lit strategy.
 *
 * Top-level uses (`final class Foo {}`, `extern final class Foo {}`)
 * keep the full `HxModifier` enum via `HxTopLevelDecl.modifiers`, where
 * `Final` IS a modifier (sealed-class marker, not a field declaration).
 *
 * The legacy `class A { final var x:Int; }` syntax (`final` modifier
 * on `var`) is consequently rejected - the modern `final x:Int;` form
 * supersedes it. No haxe-formatter fork fixture uses the legacy form;
 * the deprecation is intentional and matches Haxe 4+ idiom. It is
 * rejected inside a `#if ... #end` guard too: `HxCondModPrefix`, the
 * element type of a conditional modifier region, omits `Final` as well
 * (deferred there rather than deprecated - see that enum).
 *
 * `Abstract` is the abstract-member modifier. `HxCondModPrefix` omits it
 * too, which is why Pony's 11 `#if (haxe_ver >= 4.2) abstract #end class
 * X` modules still do not parse: in THAT shape the keyword introduces an
 * abstract CLASS, which is decl dispatch (`HxDecl.AbstractClassDecl`),
 * not a member modifier, so admitting it here would not be the same
 * capability. Both belong to the abstract/final-in-decl-keyword-slot
 * slice.
 *
 * `Macro` is the macro-function modifier (`macro function f()` /
 * `public static macro function g()`). It is member-position only and
 * is deliberately absent from `HxModifier` - `macro class`/`macro
 * typedef` are not valid Haxe, so the top-level modifier set must not
 * accept it. The expression-position `macro {...}` reification keyword
 * is a separate grammar concern and is unaffected: the modifier Star
 * only runs at member-declaration start. `HxCondModPrefix` does carry
 * `Macro`, because a guarded region reached from either scope may splice
 * it (`public static #if !macro macro #end function includeFile(...)` in
 * the Haxe standard library's `haxe.macro.Compiler`). `HxCondModPrefix`
 * is shared by both scopes' `Conditional` ctors, so INSIDE a guard the
 * `HxModifier` / `HxMemberModifier` split is not enforced - the parser
 * accepts `private #if a macro #end class C {}`. That is permissiveness
 * only, consistent with semantic validation not being the parser's job.
 *
 * Keyword-only branches are zero-arg. The generated parser enforces
 * word boundaries via `expectKw` so `publicly` does not partially
 * match `public`.
 *
 * The `Conditional` branch covers
 * `#if <cond> <entries> [#elseif ...] [#else ...] #end` preprocessor
 * regions interleaved with real modifiers (haxe-formatter fixtures:
 * `issue_107_inline_sharp`, `issue_291_conditional_modifier`,
 * `issue_332_conditional_modifiers`). Its inner body uses
 * `HxCondModPrefix` via `HxConditionalMod` - a widened element type that
 * admits metadata tags and the bare `enum` / `macro` keywords alongside
 * the plain modifier keywords, so a branch straddling the
 * modifier/metadata boundary (`#if (haxe_ver >= 4.2) extern #else
 * @:extern #end`, Pony's dominant shape) parses as one region.
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

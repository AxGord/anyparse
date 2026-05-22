package anyparse.grammar.haxe;

/**
 * Access and storage modifiers for class / interface / abstract
 * members. Mirror of `HxModifier` minus `Final` — at the member
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
 * on `var`) is consequently rejected — the modern `final x:Int;` form
 * supersedes it. No haxe-formatter fork fixture uses the legacy form;
 * the deprecation is intentional and matches Haxe 4+ idiom.
 *
 * `Macro` is the macro-function modifier (`macro function f()` /
 * `public static macro function g()`). It is member-position only and
 * is deliberately absent from `HxModifier` — `macro class`/`macro
 * typedef` are not valid Haxe, so the top-level modifier set must not
 * accept it. The expression-position `macro {...}` reification keyword
 * is a separate grammar concern and is unaffected: the modifier Star
 * only runs at member-declaration start.
 *
 * Keyword-only branches are zero-arg. The generated parser enforces
 * word boundaries via `expectKw` so `publicly` does not partially
 * match `public`.
 *
 * The `Conditional` branch covers `#if <cond> <modifiers> #end`
 * preprocessor regions interleaved with real modifiers
 * (haxe-formatter fixtures: `issue_107_inline_sharp`,
 * `issue_291_conditional_modifier`, `issue_332_conditional_modifiers`).
 * Its inner body uses the broader `HxModifier` enum via
 * `HxConditionalMod`, so legacy `final var x:Int;` inside a `#if`
 * block remains accepted — narrowly scoped exception for compatibility
 * with conditional regions that haven't migrated to the new form.
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
	Conditional(inner:HxConditionalMod);
}

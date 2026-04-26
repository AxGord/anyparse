package anyparse.grammar.haxe;

/**
 * Access and storage modifiers — top-level form, used by
 * `HxTopLevelDecl.modifiers` for `private`/`extern`/`final`/… in front
 * of a `class`/`typedef`/`enum`/`interface`/`abstract` declaration.
 * `Final` here is the sealed-class marker (`final class Foo {}`), not
 * a field-declaration introducer.
 *
 * Class / interface / abstract members route through
 * `HxMemberModifier` (the same enum minus `Final`), so member-level
 * `final` reaches `HxClassMember.FinalMember` instead of being eaten
 * as a modifier. See `HxMemberModifier` for the rationale and the one
 * narrow exception (`HxConditionalMod` body still references this
 * full enum so legacy `#if X final var x:Int; #end` remains accepted).
 *
 * Keyword-only branches are zero-arg. The generated parser enforces
 * word boundaries via `expectKw` so `publicly` does not partially match
 * `public`.
 *
 * The `Conditional` branch covers `#if <cond> <modifiers> #end`
 * preprocessor regions interleaved with real modifiers (haxe-formatter
 * fixtures: `issue_107_inline_sharp`, `issue_291_conditional_modifier`,
 * `issue_332_conditional_modifiers`). `@:kw('#if')` dispatches on the
 * `#if` keyword with a non-word-char boundary check (so `#iff` is
 * rejected); `@:trail('#end')` consumes the closing directive after
 * `HxConditionalMod` parses the cond atom and modifier body. Nested
 * `#if` is supported transitively because the body re-enters
 * `HxModifier`.
 *
 * Semantic validation (rejecting `public private`, enforcing that the
 * `#if` condition actually evaluates to something, etc.) is not the
 * parser's responsibility — it belongs to a later analysis pass.
 */
@:peg
enum HxModifier {
	@:kw('public') Public;
	@:kw('private') Private;
	@:kw('static') Static;
	@:kw('inline') Inline;
	@:kw('override') Override;
	@:kw('final') Final;
	@:kw('dynamic') Dynamic;
	@:kw('extern') Extern;

	@:kw('#if') @:trail('#end')
	Conditional(inner:HxConditionalMod);
}

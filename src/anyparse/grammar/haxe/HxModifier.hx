package anyparse.grammar.haxe;

/**
 * Access and storage modifiers for class members.
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

package anyparse.grammar.haxe;

/**
 * Access and storage modifiers — top-level form, used by
 * `HxTopLevelDecl.modifiers` for `private`/`extern`/… in front of a
 * `class`/`typedef`/`enum`/`interface`/`abstract` declaration.
 *
 * `Final` is deliberately NOT a modifier here. At the top-level scope
 * `final` is ambiguous between the sealed-class marker
 * (`final class Foo {}`) and a module-level immutable binding
 * (`final FOO = 1;`). The grammar carries no lookahead, and a greedy
 * try-parse modifier Star would eat the `final` of `final FOO = 1;`
 * and then fail dispatch. So `final` is handled entirely at decl
 * dispatch by `HxDecl.FinalDecl` → `HxFinalDecl` (ordered class-vs-var
 * first-match with rollback) — the exact analog of `HxMemberModifier`
 * dropping `Final` so member-level `final` reaches
 * `HxClassMember.FinalMember`. `HxConditionalMod` shares this enum, so
 * `final` inside a `#if … #end` modifier region is consequently no
 * longer accepted (no haxe-formatter fixture exercises that legacy
 * form; the modern `final` decl forms are covered at dispatch).
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
	@:kw('dynamic') Dynamic;
	@:kw('extern') Extern;
	@:kw('overload') Overload;

	@:kw('#if') @:trail('#end')
	Conditional(inner:HxConditionalMod);
}

package anyparse.grammar.haxe;

/**
 * Access and storage modifiers - top-level form, used by `HxTopLevelDecl.modifiers` for
 * `private`/`extern`/... in front of a `class`/`typedef`/`enum`/`interface`/`abstract`
 * declaration.
 *
 * `Final` is deliberately NOT a modifier here. At the top-level scope `final` is ambiguous
 * between the sealed-class marker (`final class Foo {}`) and a module-level immutable binding
 * (`final FOO = 1;`); the grammar carries no lookahead, and a greedy try-parse modifier Star
 * would eat the `final` of `final FOO = 1;` and then fail dispatch. So `final` is handled
 * entirely at decl dispatch by `HxDecl.FinalDecl` -> `HxFinalDecl` (ordered class-vs-var
 * first-match with rollback) - the analog of `HxMemberModifier` dropping `Final` so
 * member-level `final` reaches `HxClassMember.FinalMember`. `HxCondModPrefix`, the element
 * type of a `#if ... #end` modifier region, also omits `Final`, for a different reason: a
 * guarded `final` / `abstract` introduces a sealed / abstract CLASS whose unguarded form is
 * decl dispatch, not a modifier - see that enum.
 *
 * Keyword-only branches are zero-arg. The generated parser enforces word boundaries via
 * `expectKw` so `publicly` does not partially match `public`.
 *
 * The `Conditional` branch covers `#if <cond> <entries> [#elseif ...] [#else ...] #end`
 * regions interleaved with real modifiers. `@:kw('#if')` dispatches on the `#if` keyword with
 * a non-word-char boundary check (so `#iff` is rejected); `@:trail('#end')` consumes the
 * closing directive after `HxConditionalMod` parses the cond atom, the entry body, the
 * `#elseif` chain and the optional `#else` arm. The region's entries are `HxCondModPrefix`, a
 * widened element type that also admits metadata tags and the bare `enum` / `macro` keywords;
 * nested `#if` is supported transitively because `HxCondModPrefix` carries its own
 * `Conditional` branch back into `HxConditionalMod`.
 *
 * Semantic validation (rejecting `public private`, evaluating the `#if` condition) is not the
 * parser's responsibility - it belongs to a later analysis pass.
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
	Conditional(inner: HxConditionalMod);

}

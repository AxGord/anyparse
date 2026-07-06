package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <case clauses> [#elseif …] [#else <case
 * clauses>] #end` preprocessor-guarded region wrapping whole `case` /
 * `default` branches of a switch body. The enclosing
 * `HxSwitchCase.Conditional` ctor consumes the `#if` keyword and the
 * trailing `#end`; this typedef covers the content between them.
 *
 * Case-scope twin of `HxConditionalMeta` / `HxConditionalMember`.
 * Live dogfood shape (typically
 * `#if false` dead code):
 *
 *   switch action {
 *       case A: doA();
 *   #if false
 *       case B: doB();
 *       case C: doC();
 *   #end
 *       case D: doD();
 *   }
 *
 * Dispatch disambiguation with statement-scope conditionals: a `#if`
 * INSIDE a case body parses first as `HxStatement.Conditional` (the
 * case-body stmt Star tries it); that branch fail-rewinds when the
 * guarded content is `case`/`default` clauses (not statements), the
 * case body ends, and the switch-cases Star dispatches THIS ctor.
 * Mixed stmt+case content inside one `#if` does not parse — no such
 * shape exists in the corpus or the dogfood tree.
 *
 * `@:tryparse` termination: the body loop attempts a case clause each
 * iteration and breaks when the next token is not `case` / `default`
 * / a nested `#if` — in legal input that terminator is `#elseif` /
 * `#else` / `#end`.
 */
@:peg
typedef HxConditionalCase = {
	var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing, conditionalBodyIndent) var body: Array<HxSwitchCase>;
	@:trivia @:tryparse @:fmt(elemSelfTrailsNewline) var elseifs: Array<HxElseifCase>;
	@:optional @:kw('#else') @:trivia @:tryparse @:fmt(padLeading, padTrailing, conditionalBodyIndent)
	var elseBody: Null<Array<HxSwitchCase>>;
};

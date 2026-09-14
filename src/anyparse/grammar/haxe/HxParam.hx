package anyparse.grammar.haxe;

/**
 * Single function parameter in a Haxe function declaration or enum constructor.
 *
 * Four branches: `Conditional(inner:HxConditionalParam)` — a `#if <cond> <params> [#elseif
 * …] [#else <params>] #end` preprocessor-guarded run of parameters, dispatched by
 * `@:kw('#if')` (word-boundary check via `matchKw`) and closed by `@:trail('#end')` on the
 * ctor, the fn-param-scope member of the cond-comp cluster; `Required(body:HxParamBody)` —
 * the canonical `name:Type` / `name:Type = default`, matched when the next token is the
 * parameter name; `Optional(body:HxParamBody)` — `?name:Type`, dispatched by `@:lead('?')`;
 * and `Rest(body:HxParamBody)` — the `...name:Type` varargs form of Haxe 4.2's spread
 * operator, dispatched by `@:lead('...')`. The body is identical after the marker, so all
 * three share `HxParamBody` (the parser will accept `...r:Int = []`; semantic rejection is a
 * later analysis-pass concern).
 *
 * The Alt-enum split was chosen over a Boolean presence flag for the same reason as
 * `HxAnonField` — the macro pipeline supports `@:optional` only on `Ref` and `Star` fields;
 * the split reuses Case 3 (single-Ref-child branch with optional lead) on all three
 * non-`Conditional` sides.
 *
 * Branch order: kw-dispatched `Conditional` FIRST, lead-dispatched `Optional` / `Rest` next,
 * the catch-all `Required` LAST — the kw-before-lead-before-catch-all convention. The `#`
 * prefix shares no overlap with `?`, `...` or any valid name terminal, so dispatch is
 * unambiguous.
 *
 * Outer-Star sep-elide: `HxFnDecl.params` is a `@:trivia @:sep(',') @:trail(')')` Star, and
 * adjacent commas around a `Conditional` element are optional —
 * `function foo(#if false bar:Int, #else baz:int, #end foobar:Int) {}`,
 * `function new(a:Bool = false #if air, b:Bool = false, #end);`. The trivia-Star Lowering
 * branch records per-element `sepAfter:Bool` from the parser's `matchLit(',')` result, and
 * the writer's `triviaSepStarExpr` `_emitSep` gate honours `sepAfter=false` to suppress the
 * inter-element comma — the mechanism object-literal fields with a missing source comma use.
 *
 * Used by `HxFnDecl.params` and `HxEnumCtorDecl.params`. The runtime sep-elide is specific to
 * the `@:trivia` Star path; `HxEnumCtorDecl.params` is non-trivia, so cond-comp inside a
 * parameterised enum constructor's params does not byte-roundtrip the no-comma adjacency
 * form. Lambda-style `?param` routes through `HxLambdaParam`; call-site spread `f(...args)`
 * is `HxExpr.Spread`, not a variant of this enum.
 */
@:peg
enum HxParam {

	@:kw('#if') @:trail('#end')
	Conditional(inner: HxConditionalParam);

	@:lead('?') Optional(body: HxParamBody);
	@:lead('...') Rest(body: HxParamBody);
	Required(body: HxParamBody);

}

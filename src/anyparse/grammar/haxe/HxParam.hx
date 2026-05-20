package anyparse.grammar.haxe;

/**
 * Single function parameter in a Haxe function declaration or enum
 * constructor.
 *
 * Four branches:
 *
 *  - `Conditional(inner:HxConditionalParam)` — a `#if <cond> <params>
 *    [#elseif …] [#else <params>] #end` preprocessor-guarded run of
 *    parameters. Dispatched by `@:kw('#if')` (word-boundary check via
 *    `matchKw`); closed by `@:trail('#end')` on the ctor. The fn-param-
 *    scope completion of the cond-comp arc (`HxDecl.Conditional` at decl
 *    scope, `HxStatement.Conditional` at stmt scope, `HxClassMember.Conditional`
 *    at member scope, `HxMemberModifier.Conditional` for a modifier run,
 *    `HxObjectField.Conditional` at obj-lit scope). Inner-body parsing
 *    reuses Slice 18's `@:sep+@:tryparse-no-close` Lowering branch via
 *    `HxConditionalParam.body`.
 *
 *  - `Required(body:HxParamBody)` — the canonical form `name:Type` or
 *    `name:Type = default`. No keyword/lead — the branch matches when
 *    the next token is the parameter name (`HxIdentLit`).
 *
 *  - `Optional(body:HxParamBody)` — the optional form `?name:Type` or
 *    `?name:Type = default`. Dispatched by `@:lead('?')`. The body is
 *    identical to `Required` after the `?` is consumed, so both
 *    branches share `HxParamBody` as their inner shape.
 *
 *  - `Rest(body:HxParamBody)` — the rest / varargs form `...name:Type`
 *    introduced by Haxe 4.2's spread operator. Dispatched by
 *    `@:lead('...')`. Reuses `HxParamBody`; rest params have no
 *    default value in valid Haxe but the body shape allows it without
 *    extra machinery (the parser will accept `...r:Int = []`; semantic
 *    rejection is a later analysis-pass concern).
 *
 * The Alt-enum-split shape was chosen over a Boolean presence flag
 * for the same reason as `HxAnonField` — the macro pipeline currently
 * supports `@:optional` only on `Ref` and `Star` fields. The split
 * keeps the macro infra unchanged and reuses Case 3 (single-Ref-child
 * branch with optional lead) on all three non-`Conditional` sides.
 *
 * Branch order: kw-dispatched `Conditional` (`@:kw('#if')`) FIRST,
 * lead-dispatched `Optional` / `Rest` (`?` / `...`) next, the
 * catch-all `Required` LAST. Mirrors `HxObjectField` (`Conditional` /
 * `Field`) and the established kw-before-lead-before-catch-all
 * convention. The `#` prefix shares no overlap with `?`, `...`, or
 * any valid name terminal, so dispatch is unambiguous.
 *
 * Outer-Star sep-elide. `HxFnDecl.params` is a `@:trivia @:sep(',')
 * @:trail(')')` Star — adjacent commas around a `Conditional` element
 * are optional. Examples (fork fixtures whitespace/issue_345 /
 * issue_397 / issue_582):
 *
 * ```haxe
 * function foo(#if openfl ?vector:openfl.Vector<Int> #end) {}
 * function foo(#if false bar:Int, #else baz:int, #end foobar:Int) {}
 * function new(isTouchPointCanceled:Bool = false #if air,
 *     commandKey:Bool = false, controlKey:Bool = false, #end);
 * ```
 *
 * The trivia-Star Lowering branch records per-element `sepAfter:Bool`
 * from the parser's `matchLit(',')` result; the writer's
 * `triviaSepStarExpr` `_emitSep` gate honours `sepAfter=false` to
 * suppress the inter-element comma. This mechanism
 * was added for lineends/issue_111 (obj-lit fields with missing source
 * comma) and is reused here unchanged — no new Lowering or Writer
 * primitive was introduced in this slice.
 *
 * Used by `HxFnDecl.params` (function-decl signature) and
 * `HxEnumCtorDecl.params` (parameterised enum constructors). The runtime
 * sep-elide via `sepAfter` is specific to the `@:trivia` Star path;
 * `HxEnumCtorDecl.params` is non-trivia, so cond-comp inside a
 * parameterised enum constructor's params would not byte-roundtrip the
 * no-comma adjacency form. No fork fixture currently exercises that
 * combination — the limitation is acceptable for this slice.
 *
 * Lambda-style `?param` routes through `HxLambdaParam` (separate
 * grammar). Call-site spread `f(...args)` is `HxExpr.Spread`, not a
 * variant of this enum.
 */
@:peg
enum HxParam {

	@:kw('#if') @:trail('#end')
	Conditional(inner:HxConditionalParam);

	@:lead('?') Optional(body:HxParamBody);
	@:lead('...') Rest(body:HxParamBody);
	Required(body:HxParamBody);
}

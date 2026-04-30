package anyparse.grammar.haxe;

/**
 * Single function parameter in a Haxe function declaration or enum
 * constructor.
 *
 * Three branches:
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
 * branch with optional lead) on all three sides.
 *
 * Branch order: lead-dispatched branches (`Optional`, `Rest`) precede
 * the fallthrough `Required`. The `?` and `...` literals share no
 * prefix so their relative order is irrelevant; only the catch-all
 * must be last. This mirrors the `HxAnonField` and `HxStatement`
 * patterns.
 *
 * Used by `HxFnDecl.params` (function-decl signature) and
 * `HxEnumCtorDecl.params` (parameterised enum constructors).
 *
 * Lambda-style `?param` routes through `HxLambdaParam` (separate
 * grammar). Call-site spread `f(...args)` is `HxExpr.Spread`, not a
 * variant of this enum.
 */
@:peg
enum HxParam {
	@:lead('?') Optional(body:HxParamBody);
	@:lead('...') Rest(body:HxParamBody);
	Required(body:HxParamBody);
}

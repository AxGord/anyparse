package anyparse.grammar.haxe;

/**
 * Single function parameter in a Haxe function declaration or enum
 * constructor.
 *
 * Two branches:
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
 * The Alt-enum-split shape was chosen over a Boolean presence flag
 * for the same reason as `HxAnonField` — the macro pipeline currently
 * supports `@:optional` only on `Ref` and `Star` fields. The split
 * keeps the macro infra unchanged and reuses Case 3 (single-Ref-child
 * branch with optional lead) on both the parser and writer sides.
 *
 * Branch order matters: `Optional` comes first so the `@:lead('?')`
 * dispatch is tried before the fallthrough `Required`. This mirrors
 * the `HxAnonField` and `HxStatement` patterns where keyword-/lead-
 * dispatched branches precede the no-guard catch-all.
 *
 * Used by `HxFnDecl.params` (function-decl signature) and
 * `HxEnumCtorDecl.params` (parameterised enum constructors).
 *
 * Varargs (`...`) and lambda-style `?param` (which routes through
 * `HxLambdaParam`) are deferred / handled separately.
 */
@:peg
enum HxParam {
	@:lead('?') Optional(body:HxParamBody);
	Required(body:HxParamBody);
}

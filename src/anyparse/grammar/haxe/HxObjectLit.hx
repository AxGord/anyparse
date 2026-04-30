package anyparse.grammar.haxe;

/**
 * Anonymous object literal expression: `{name1: value1, name2: value2}`.
 *
 * Wraps a comma-separated list of `HxObjectField` entries between `{`
 * and `}` delimiters. Empty literal `{}` is valid (zero fields) —
 * handled by the sep-peek Star mode's close-char guard before any
 * element parse (same pattern as empty `()` in `HxParenLambda.params`
 * and empty `[]` in `HxExpr.ArrayExpr`).
 *
 * The `@:lead('{')` on the Star field is the branch's peek-and-commit
 * point when `ObjectLit` is dispatched inside `HxExpr` — non-`{` input
 * rolls the enum's `tryBranch` back to the next atom candidate.
 *
 * Ambiguity at statement-top-level (`{name: value};`) with
 * `HxStatement.BlockStmt` (also `@:lead('{')`) is deferred — the
 * corpus only exercises object literals inside expression contexts
 * (function arguments, binary-operator right-hand sides) where no
 * block-statement parser competes.
 *
 * `@:fmt(objectLiteralBracesOpen, objectLiteralBracesClose)` routes the
 * inside-of-braces spacing through `delimInsidePolicySpace` — same
 * mechanism as `@:fmt(typeParamOpen, typeParamClose)` on
 * `HxTypeRef.params` and `@:fmt(anonTypeBracesOpen, anonTypeBracesClose)`
 * on `HxType.Anon`. Defaults `None`/`None` keep `{a: 1}` tight.
 */
@:peg
typedef HxObjectLit = {
	@:fmt(objectLiteralBracesOpen, objectLiteralBracesClose) @:lead('{') @:trail('}') @:sep(',') @:trivia var fields:Array<HxObjectField>;
}

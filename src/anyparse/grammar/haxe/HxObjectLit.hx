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
 *
 * `@:fmt(wrapRules('objectLiteralWrap'))` (slice ω-wraprules-objlit)
 * routes the multi-line wrap decision through the runtime
 * `WrapList.emit` engine driven by the `objectLiteralWrap:WrapRules`
 * cascade on `opt`. The engine measures item count + max/total flat
 * width, evaluates the cascade twice (`exceeds=false` + `exceeds=true`)
 * and picks one of `NoWrap` / `OnePerLine` / `OnePerLineAfterFirst` /
 * `FillLine` shapes — wrapping the result in
 * `Group(IfBreak(brkDoc, flatDoc))` when the two runs disagree, so the
 * renderer's flat/break decision selects the right mode at layout time.
 * Default rules are ported from haxe-formatter's
 * `wrapping.objectLiteral` (`HaxeFormat.defaultObjectLiteralWrap`):
 * `noWrap` if `count <= 3 ∧ ¬exceeds`, else `onePerLine` if any item
 * ≥ 30 cols / total ≥ 60 cols / count ≥ 4 / line exceeds `lineWidth`.
 * Architecturally orthogonal to the `objectLiteralBracesOpen`/`Close`
 * interior-spacing policies — wrap decides single-line vs multi-line
 * shape, braces decide the `{a:1}`/`{ a:1 }` interior spacing of the
 * single-line variant.
 */
@:peg
typedef HxObjectLit = {
	@:fmt(objectLiteralBracesOpen, objectLiteralBracesClose, wrapRules('objectLiteralWrap')) @:lead('{') @:trail('}') @:sep(',') @:trivia var fields:Array<HxObjectField>;
}

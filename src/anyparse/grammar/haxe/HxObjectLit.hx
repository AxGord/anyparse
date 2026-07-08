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
 *
 * `@:fmt(leftCurly('objectLiteralLeftCurly'))` (slice
 * ω-objectlit-leftCurly) routes the `{` placement through the
 * per-construct `opt.objectLiteralLeftCurly:BracePlacement` knob
 * instead of the global `opt.leftCurly`. The loader cascade in
 * `HaxeFormatConfigLoader.applyLineEnds` writes the global
 * `lineEnds.leftCurly` into both knobs while
 * `lineEnds.objectLiteralCurly.leftCurly` overrides only the
 * per-construct one — mirroring haxe-formatter's
 * `MarkLineEnds.getCurlyPolicy(ObjectDecl)` precedence.
 *
 * `@:fmt(rightCurly('objectLiteralRightCurly'))` (slice
 * ω-objectlit-right-curly) routes the hardline emitted immediately
 * before `}` through the per-construct
 * `opt.objectLiteralRightCurly:RightCurlyPlacement` knob. `Same`
 * (default) keeps `\n}` so the close sits on its own line; `Inline`
 * drops the before-close hardline so `}` glues to the last field.
 * The loader cascade writes the global `lineEnds.rightCurly` into
 * this knob alongside `blockRightCurly` / `anonFunctionRightCurly` /
 * `anonTypeRightCurly`; per-construct sub-key
 * `lineEnds.objectLiteralCurly.rightCurly` overrides the cascade.
 * Dispatch fires only in `triviaSepStarExpr`'s trivia branch — the
 * wrap-engine branch (no per-element trivia) continues to use
 * `WrapList.emit`'s shape close emission.
 *
 * `@:fmt(trailingComma('trailingCommaObjectLits'))` (slice
 * ω-objectlit-trailing-comma) routes the trailing-comma-on-break
 * decision through the per-construct `opt.trailingCommaObjectLits:Bool`
 * knob, mirroring the sibling `trailingCommaArrays` /
 * `trailingCommaArgs` / `trailingCommaParams` flags. Default `false`
 * preserves the pre-slice byte-identical layout for every fork fixture
 * — capability foundation for future metadata-prefix-aware obj-lit
 * rules in `HxMetaExpr` writers.
 *
 * leftCurly emission for this field is owned by `triviaSepStarExpr`
 * (slice ω-objectlit-leftCurly-cascade). Two runtime paths:
 *  - trivia-bearing: any element has `newlineBefore` / leading /
 *    trailing comment trivia → BodyGroup with forced hardlines;
 *    leftCurly Doc is prepended unconditionally (`_dhl()` for Next,
 *    `_de()` for Same).
 *  - no-trivia: clean inline list → routes through `WrapList.emit`
 *    with `(leadFlat=_de(), leadBreak=_dhl())` for Next, both `_de()`
 *    for Same. The engine's `Group(IfBreak)` wrap picks cuddled vs
 *    Allman per the wrap cascade's flat/break decision — short
 *    literals chosen NoWrap stay cuddled even under `Next`.
 *
 * `@:fmt(reflowInExprPosition)` (slice ω-expressionif-collapse) — when
 * `opt._inValueIfBranch` is set at write time (this object literal is the
 * immediate value of a value-yielded `if`/`else` branch, propagated by
 * `HxIfExpr.thenBranch` / `elseBranch`'s `@:fmt(propagateValueIfBranch)`),
 * the sep-Star's Ignore-mode check fires, dropping element `newlineBefore`
 * signals so the wrap cascade collapses a source-multiline literal to
 * single-line. Combined with the `objectLiteralBracesOpen`/`Close` padding
 * this yields `{ width: VALUE_C, height: VALUE_D }` from a multi-line
 * source branch value. Source-multiline object literals in every OTHER
 * context (var-init, call-args, array-elements) keep their shape because
 * the flag is cleared on each expression-position descent.
 *
 * `@:fmt(arrowBodyOpenPadSuppress)` (slice ω-arrow-body-objlit-pad) —
 * when `opt._inArrowLambdaBody` is set at write time (this literal is
 * the leftmost leaf of an arrow-lambda body, propagated by
 * `HxExpr.ThinArrow`'s right operand / `HxThinParenLambda.body`'s
 * `@:fmt(propagateArrowLambdaBody)`), the open-side
 * `objectLiteralBracesOpen` inner pad is dropped — mirroring fork
 * `MarkWhitespace.successiveParenthesis`'s compress-mode `case Arrow:
 * return;` which never applies the opening-brace policy to a `{` whose
 * previous token is `->` (`u -> {email: v }`, not `u -> { email: v }`).
 * The close-side pad is unaffected. Cleared by `_setExprPosition` on
 * every fresh expression-position descent, so only the literal whose
 * `{` sits right after the `->` token sees the flag.
 */
@:peg
typedef HxObjectLit = {
	@:fmt(objectLiteralBracesOpen, objectLiteralBracesClose, wrapRules('objectLiteralWrap'), leftCurly('objectLiteralLeftCurly'),
		rightCurly('objectLiteralRightCurly'), trailingComma('trailingCommaObjectLits'), reflowInExprPosition, arrowBodyOpenPadSuppress) @:lead('{') @:trail('}') @:sep(',') @:trivia var fields: Array<HxObjectField>;
}

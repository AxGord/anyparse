package anyparse.grammar.haxe;

/**
 * Anonymous object literal expression: `{name1: value1, name2: value2}` — a comma-separated
 * list of `HxObjectField` entries between `{` and `}`; the empty `{}` is handled by the
 * sep-peek Star mode's close-char guard. The `@:lead('{')` on the Star field is the branch's
 * peek-and-commit point inside `HxExpr`. Ambiguity at statement top level (`{name: value};`)
 * with `HxStatement.BlockStmt` is deferred — literals occur in expression contexts.
 *
 * `@:fmt(objectLiteralBracesOpen, objectLiteralBracesClose)` routes the inside-of-braces
 * spacing through `delimInsidePolicySpace` (the `typeParamOpen` / `anonTypeBracesOpen`
 * mechanism); defaults `None`/`None` keep `{a: 1}` tight. `@:fmt(wrapRules(
 * 'objectLiteralWrap'))` routes the multi-line wrap decision through `WrapList.emit` driven
 * by the `objectLiteralWrap:WrapRules` cascade: the engine measures item count and
 * max/total flat width, evaluates the cascade for both `exceeds` values and picks `NoWrap` /
 * `OnePerLine` / `OnePerLineAfterFirst` / `FillLine`, wrapping the result in
 * `Group(IfBreak(brkDoc, flatDoc))` when the two runs disagree; the default rules are
 * haxe-formatter's `wrapping.objectLiteral` (`HaxeFormat.defaultObjectLiteralWrap`). Wrap
 * decides single- vs multi-line shape; the brace policies decide the interior spacing.
 *
 * `@:fmt(leftCurly('objectLiteralLeftCurly'))` reads the per-construct
 * `opt.objectLiteralLeftCurly` knob (global `lineEnds.leftCurly` seeds it,
 * `lineEnds.objectLiteralCurly.leftCurly` overrides), the fork's `getCurlyPolicy(ObjectDecl)`.
 * Emission is owned by `triviaSepStarExpr`: a trivia-bearing list becomes a BodyGroup with
 * forced hardlines and the leftCurly Doc prepended unconditionally; a clean inline list
 * routes through `WrapList.emit` with `(leadFlat=_de(), leadBreak=_dhl())` for `Next`, so a
 * short literal chosen NoWrap stays cuddled even under `Next`.
 * `@:fmt(rightCurly('objectLiteralRightCurly'))` routes the hardline before `}` through the
 * per-construct knob (`Same` keeps `\n}`, `Inline` glues `}`); trivia branch only.
 *
 * `@:fmt(trailingComma('trailingCommaObjectLits'))` reads the per-construct
 * trailing-comma-on-break knob (default `false`); `@:fmt(trailingCommaRemovable)` opts the
 * list into `wrapping.trailingComma` — under `remove` a broken literal never ends with a
 * `,`, while a FLAT `{a: 1,}` keeps its source comma. `@:fmt(reflowInExprPosition)` — when
 * `opt._inValueIfBranch` is set (the literal is the immediate value of a value-yielded
 * `if`/`else` branch), the sep-Star's Ignore-mode check drops element `newlineBefore`
 * signals so a source-multiline literal collapses to one line; the flag is cleared on each
 * expression-position descent. `@:fmt(arrowBodyOpenPadSuppress)` — when
 * `opt._inArrowLambdaBody` is set (the literal is the leftmost leaf of an arrow-lambda body),
 * the open-side inner pad is dropped (`u -> {email: v }`), the fork's `case Arrow: return;`;
 * `objectLiteralBraces.arrowBodyOpenPad: true` keeps the pad, a deliberate divergence.
 */
@:peg
typedef HxObjectLit = {
	@:fmt(objectLiteralBracesOpen, objectLiteralBracesClose, wrapRules('objectLiteralWrap'), leftCurly('objectLiteralLeftCurly'),
		rightCurly('objectLiteralRightCurly'), trailingComma('trailingCommaObjectLits'), trailingCommaRemovable, reflowInExprPosition,
		arrowBodyOpenPadSuppress, groupRestProbe) @:lead('{') @:trail('}') @:sep(',') @:trivia var fields: Array<HxObjectField>;
}

package anyparse.grammar.haxe;

/**
 * Expression-position `if` — `if (cond) thenBranch [else elseBranch]` used where a value is expected.
 * Structurally parallel to `HxIfStmt` but both branches are `HxExpr`; the statement construct still dispatches
 * through `HxStatement.IfStmt` because `IfStmt` sits ahead of `ExprStmt` in `HxStatement`. Dangling-else
 * follows the same rule: the nearest enclosing `if` greedily consumes the next `else`.
 *
 * `thenBranch` carries `@:trailOpt(';')`: Haxe accepts an optional `;` terminating the then-branch before
 * `else` (`final x = if (c) a; else b;`); the `;` is consumed, not stored, and the source-presence synth slot
 * decides re-emission. `@:fmt(semicolonBeforeSibling('elseBranch', 'sameLineExpressionElse'))` lets
 * `whitespace.semicolonBeforeElse` answer that slot from the policy, but ONLY when `elseBranch` is non-null:
 * with NO `else` the same slot can be holding the ENCLOSING statement's terminator, and dropping it there
 * would emit code that does not compile. `@:fmt(valueBraceSymmetry('<sibling>', 'BlockExpr', 'ExprStmt',
 * 'IfExpr', 'SwitchExpr', 'SwitchExprBare', 'ObjectLit'))` on BOTH branches — under `singleStatementBraces:
 * "remove"` a branch whose SIBLING is a `{ … }` block gains braces of its own (the value twin of
 * `SingleStmtBraces` gate 7, built by the same `wrapInBlock` with a lift into `ExprStmt`); an `else if` chain
 * member and a brace-LED value are excluded, and the skip lists of the two positions must agree per ctor
 * family (`unit.format.BraceSymmetrySliceTest`). When the wrap fires on `thenBranch` the `@:trailOpt` slot is
 * suppressed — the synthesized block already carries the terminator, so the source `;` would land after the
 * closing brace.
 *
 * Layout: `@:fmt(bodyPolicy('ifBody', 'expressionIfBody'))` / `bodyPolicy('elseBody', 'expressionElseBody')` —
 * the dual form reads the second knob under `opt._inExprPosition`, the statement knob otherwise; the
 * expression knobs are distinct from `HxIfStmt`'s, compiled default `Same` for both (`expressionForBody`
 * `Keep`), and the `sameLine.expressionIf` key fans `keep` / `same` into all three and `next` / `fitLine` into
 * the if/else pair only. `elseBranch` carries `@:fmt(sameLine('sameLineExpressionElse'))` for the pre-`else`
 * gap (`Keep` consults the synth `elseBranchBeforeKwNewline` slot) and `@:fmt(shapeAware)`: a non-block
 * `thenBranch` under `Next` / `FitLine` forces a hardline before `else`; a block-shape `thenBranch` keeps a
 * flag-driven separator, split by delimiter — a CURLY close reads `sameLinePolicySwitch` (`SameOnBlock` falls
 * through to a space, so `} else {` cuddles), a BRACKET close reads `sameLineNonCurlyBlockPolicySwitch`
 * (`SameOnBlock` routes to `Keep`, so gluing `]` stays `expressionIfWithBrackets`'s job).
 * `@:fmt(elseSwitch(...))` on BOTH branches is the value twin of the statement form's meta (see `HxIfStmt`).
 * `@:fmt(elseIf)` on `elseBranch` routes an `else if` chain through `opt.elseIf` instead of
 * `expressionElseBody`. `@:fmt(noSiblingFallback('ifBody'))` on `thenBranch` swaps `opt.expressionIfBody` for
 * `opt.ifBody` when `elseBranch` is null (the fork's `markIf` short-circuits for an arrow-body or
 * comprehension-filter `if`) — the inverse polarity of `HxIfStmt`'s `fitLineIfWithElse`.
 *
 * `@:fmt(inlineBlockBodyIfFlag('expressionIfWithBlocks'))` on both branches flattens a `BlockExpr` body to
 * `{stmt;}` under the knob (opt-in; trivia-mode `//` comments inside the block break syntax, as in the fork).
 * `@:fmt(bracketBodyGlueIfFlag('expressionIfWithBrackets'))` is the `[` sibling and owns THREE seams keyed on
 * the flag alone: the branch value hugs its head, the `@:trailOpt(';')` slot is dropped when an `elseBranch`
 * follows, and the pre-`else` gap becomes a plain space — without the close seams a source that wrote `];` on
 * its own line keeps `else` on the next one. `@:fmt(indentValueIfCtor('ObjectLit', 'indentObjectLiteral',
 * 'objectLiteralLeftCurly'))` on `thenBranch` drops the Next-layout's outer Nest for a multi-line object
 * literal under `indentObjectLiteral=false`; `elseBranch` does not carry it because its optional-kw path is
 * excluded from the gate. `@:fmt(propagateValueIfBranch)` on both branches sets `opt._inValueIfBranch` on the
 * direct value write, read by `HxObjectLit`'s `reflowInExprPosition`.
 *
 * `@:fmt(arrowValueIfReflowSite)` on both branches, paired with the TYPE-level
 * `@:fmt(arrowValueIfReflow('expressionIfArrowBodyReflow', 'elseBranch', 'IfExpr', …))`, is the one context
 * the `expressionIf` cascade cannot canonicalise: a value-if chain in an arrow-lambda body. The type-level
 * meta wraps the node in a `Group`, the field flags make both branch policies read `Same` and the pre-`else`
 * gap a soft `Line`, so the chain has ONE break axis decided for every arm at once; only the OUTERMOST chain
 * member opens the group (`!opt._inValueIfBranch`). The reflow is REFUSED for the chain as a whole when any
 * member carries a captured comment, in both directions (an `else`-spine walk sees comments BELOW,
 * `opt._arrowValueIfBlocked` stamps a refusal for members ABOVE). `_inArrowLambdaBody` also reaches a
 * `cast(<if>, T)` operand, a prefix keyword and an enclosing value-`if`'s CONDITION, which re-flow under the
 * knob too; recorded rather than gated.
 */
@:peg
@:fmt(arrowValueIfReflow('expressionIfArrowBodyReflow', 'elseBranch', 'IfExpr', 'expressionIfFit'))
typedef HxIfExpr = {
	@:lead('(') @:trail(')') @:fmt(condWrap('conditionWrap')) var cond: HxExpr;
	@:trailOpt(';') @:fmt(bodyPolicy('ifBody', 'expressionIfBody'),
		indentValueIfCtor('ObjectLit', 'indentObjectLiteral', 'objectLiteralLeftCurly'), noSiblingFallback('ifBody'),
		inlineBlockBodyIfFlag('expressionIfWithBlocks'), bracketBodyGlueIfFlag('expressionIfWithBrackets'), propagateValueIfBranch,
		arrowValueIfReflowSite, semicolonBeforeSibling('elseBranch', 'sameLineExpressionElse'),
		elseSwitch('elseSwitch', 'SwitchExpr', 'SwitchExprBare'),
		valueBraceSymmetry('elseBranch', 'BlockExpr', 'ExprStmt', 'IfExpr', 'SwitchExpr', 'SwitchExprBare', 'ObjectLit'))
	var thenBranch: HxExpr;
	@:optional @:kw('else') @:fmt(bodyPolicy('elseBody', 'expressionElseBody'), sameLine('sameLineExpressionElse'), shapeAware, elseIf,
		elseSwitch('elseSwitch', 'SwitchExpr', 'SwitchExprBare'), inlineBlockBodyIfFlag('expressionIfWithBlocks'),
		bracketBodyGlueIfFlag('expressionIfWithBrackets'), propagateValueIfBranch, arrowValueIfReflowSite,
		valueBraceSymmetry(
			'thenBranch', 'BlockExpr', 'ExprStmt', 'IfExpr', 'SwitchExpr', 'SwitchExprBare', 'ObjectLit'
		)) var elseBranch: Null<HxExpr>;
};

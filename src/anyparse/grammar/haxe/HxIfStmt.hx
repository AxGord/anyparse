package anyparse.grammar.haxe;

/**
 * If-statement grammar: `if (cond) thenBody [else elseBody]`. The condition is wrapped in
 * mandatory parentheses (`@:lead('(')` / `@:trail(')')` on `cond`); the then-body is a bare
 * `HxStatement` Ref; the else-body is `@:optional @:kw('else')` — the `else` keyword is the
 * commit point. A bare non-`;`-terminated then-body before `else` (`if (c) foo() else { … }`)
 * is accepted by the `ExprStmt` trail gate (the `;` is optional when `else` immediately
 * follows, consumed-not-stored); with NO `else` before a block-end (`{ if (c) foo() }`) it
 * is still rejected — relaxing `;` before `}` would break the Star-loop statement boundary.
 *
 * `@:fmt(sameLine("sameLineElse"))` on `elseBody` makes the separator between the then-body
 * and `else` runtime-switchable (`} else {` vs `}\n    else {`). `@:fmt(shapeAware)` (ψ₉)
 * opts that flag into shape-awareness on the preceding sibling: a non-block `thenBody`
 * forced onto its own line suppresses the space in favour of a hardline regardless of the
 * flag. `@:fmt(semicolonNextLineElse)` (ψ₆) is the inline-shape counterpart: when the
 * then-body is forced inline, `else` breaks onto its own line if the then-body's trailing
 * `;` was present in source AND `opt.ifElseSemicolonNextLine` is true (haxe-formatter's
 * `markElse` Semicolon branch). Both live on `HxIfStmt.elseBody` ONLY — `HxIfExpr.elseBranch`
 * is governed by `sameLineExpressionElse` and keeps `else` glued.
 *
 * `@:fmt(elseIf)` on `elseBody` activates the `opt.elseIf:KeywordPlacement` knob: when the
 * else branch is itself an `if`, the separator is picked from `opt.elseIf`, so `else if
 * (...)` stays inline even though `elseBody=Next` pushes other branches to the next line.
 * `@:fmt(elseIfCommentReflow)` opts the `elseIf` glue path into `opt.elseIfCommentReflow`: on
 * the `Same` arm only, the `kwGapDoc` separator drops to a plain space and the one captured
 * `//` comment is spliced into the built body Doc by `ElseIfCommentReflow.insertHeadTrail`
 * at the first UNCONDITIONAL break after the condition; the splice fails closed to the
 * untouched layout on any other trivia shape or when no anchor is found (a flat body, an
 * EMPTY then-body, a head already carrying a trailing `//`). Trivia mode only.
 *
 * `@:fmt(fitLineIfWithElse)` on BOTH bodies (ψ₁₂) gates the `FitLine` policy on sibling-else
 * presence: when `opt.fitLineIfWithElse` is `false` (default) and the `if` has an `else`, the
 * body falls back to `Next` — fitting one half and breaking the other reads as inconsistent.
 * `@:fmt(elseSwitch('elseSwitch', 'SwitchStmt', 'SwitchStmtBare'))` on BOTH bodies: a `switch`
 * branch under `opt.elseSwitch == Same` glues to its keyword's line the way `elseIf` glues a
 * nested `if`. The THEN branch owns a SECOND seam: a glued `switch` closes with a `}` in the
 * `if` head's column, so the separator asks the PREVIOUS FIELD whether it glued
 * (`PrevBodyInfo.headGlue`) and routes a glued close to `sameLineElse` as a curly close is
 * routed. `@:fmt(dropSingleStmtBraces)` on BOTH bodies opts into `opt.dropSingleStmtBraces`
 * (`SingleStmtBraces.unwrapStmt`, trivia mode only, every safety gate fails closed).
 */
@:peg
typedef HxIfStmt = {
	@:lead('(') @:trail(')') @:fmt(condWrap('conditionWrap'), condParensInside('ifCondParensInsideOpen', 'ifCondParensInsideClose'),
		captureCondOpenNewline) var cond: HxExpr;
	@:trailOpt(';') @:fmt(bodyPolicy('ifBody', 'expressionIfBody'), fitLineIfWithElse, clearElseIfBranch,
		elseSwitch('elseSwitch', 'SwitchStmt', 'SwitchStmtBare'), dropSingleStmtBraces) var thenBody: HxStatement;
	@:optional @:trailOpt(';') @:kw('else') @:fmt(sameLine('sameLineElse'), shapeAware, semicolonNextLineElse,
		bodyPolicy('elseBody', 'expressionElseBody'), elseIf, elseSwitch('elseSwitch', 'SwitchStmt', 'SwitchStmtBare'),
		elseIfCommentReflow, fitLineIfWithElse, propagateElseIfBranch, dropSingleStmtBraces) var elseBody: Null<HxStatement>;
};

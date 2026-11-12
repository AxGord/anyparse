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
 * `@:fmt(sameLine("sameLineElse"))` on `elseBody` makes the then-body → `else` separator
 * runtime-switchable; `@:fmt(shapeAware)` (ψ₉) turns it into a hardline after a non-block
 * `thenBody` forced onto its own line, and `@:fmt(semicolonNextLineElse)` (ψ₆) breaks before
 * `else` after an inline then-body whose source `;` was present when
 * `opt.ifElseSemicolonNextLine` is set. `HxIfExpr.elseBranch` keeps `else` glued instead.
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
 * `@:fmt(ifElseLadder)` on BOTH bodies makes an `if` / `else` chain a ladder in every config: a
 * branch body without braces of its own sits on its own line one indent deeper, whatever its
 * placement and width, while a block or a glued `switch` keeps its glue. An `if` with no `else`
 * that is not an `else if` link is no chain and keeps its placement.
 * `@:fmt(elseSwitch('elseSwitch', 'SwitchStmt', 'SwitchStmtBare'))` on BOTH bodies: a `switch`
 * branch under `opt.elseSwitch == Same` glues to its keyword's line the way `elseIf` glues a
 * nested `if`. The THEN branch owns a SECOND seam: a glued `switch` closes with a `}` in the
 * `if` head's column, so the separator asks the PREVIOUS FIELD whether it glued
 * (`PrevBodyInfo.headGlue`) and routes a glued close to `sameLineElse` as a curly close is
 * routed. `@:fmt(dropSingleStmtBraces)` on BOTH bodies opts into `opt.dropSingleStmtBraces`
 * (`SingleStmtBraces.unwrapStmt`, trivia mode only, every safety gate fails closed). A source
 * `;` after either body (`if (c) { … };`) lands in its `@:trailOpt(';')` slot and is written
 * back glued: redundant after a `}`, it is the `empty-statement` lint's to remove, while after a
 * `#if` region body (`… #end;`) it is the statement's own terminator.
 */
@:peg
typedef HxIfStmt = {
	@:lead('(')
	@:trail(')')
	@:fmt(condWrap('conditionWrap'), condParensInside('ifCondParensInsideOpen', 'ifCondParensInsideClose'))
	var cond: HxExpr;
	@:trailOpt(';')
	@:fmt(bodyPolicy('ifBody', 'expressionIfBody'), ifElseLadder, clearElseIfBranch,
		elseSwitch('elseSwitch', 'SwitchStmt', 'SwitchStmtBare'), dropSingleStmtBraces)
	var thenBody: HxStatement;
	@:optional
	@:trailOpt(';')
	@:kw('else')
	@:fmt(sameLine('sameLineElse'), shapeAware, semicolonNextLineElse, bodyPolicy('elseBody', 'expressionElseBody'), elseIf,
		elseSwitch('elseSwitch', 'SwitchStmt', 'SwitchStmtBare'), elseIfCommentReflow, ifElseLadder, propagateElseIfBranch,
		dropSingleStmtBraces)
	var elseBody: Null<HxStatement>;
};

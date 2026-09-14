package anyparse.grammar.haxe;

/**
 * Grammar for a single `case pattern: body` branch inside a switch; the `case` keyword is consumed at the
 * enum-branch level (`@:kw('case')` on `HxSwitchCase.CaseBranch`).
 *
 * `patterns` is a `@:sep(',') @:trail(':')` Star of `HxCasePattern`; each element's `expr` parses as `HxExpr`
 * and carries the optional `if (cond)` guard (see `HxCasePattern`). `@:fmt(wrapRules('casePatternWrap'))`
 * routes the list through `WrapList.emit` with the `casePatternWrap` cascade; the Star has no `@:lead`, so the
 * first pattern stays inline. `@:fmt(beforeNewlineSlotFirst)` (ω-casepattern-keep) opts this FIRST field into
 * the source-newline-before capture (paired with `@:fmt(forwardNewlineForBody)` on the parent ctor): the synth
 * `patternsBeforeNewline:Bool` slot lets the writer reproduce `case\n\t{pattern}` verbatim under
 * `opt.leftCurly == Next`.
 *
 * `body` uses `@:tryparse` termination on the last field: the loop breaks on `case`, `default` or `}`, none of
 * which parse as an `HxStatement`. `@:fmt(nestBody)` wraps the body Doc in an extra indent level.
 * `@:fmt(bodyPolicy('caseBody', 'expressionCase'))` exposes the dual knobs that gate single-stmt-flat
 * emission: `case X: foo();` is emitted flat when the body has exactly one statement with no leading or
 * orphan-trailing comments AND either flag is `Same`, or either flag is `Keep` and the body's first element
 * has no `newlineBefore` (compiled default `Keep` for both; `HaxeFormatConfigLoader` re-baselines `caseBody`
 * to the fork's `Next` on any JSON load). Under `FitLine` the same eligibility fires `_fitCase` and hands the
 * body to `anyparse.format.BodyFit.fitLineLayout`, the emitter that also serves bare-Ref bodies: a body that
 * can render on one line at all becomes `BodyGroup(Nest(cols, [Line, body]))` — inline when it fits the live
 * line, else the WHOLE body drops one indent deeper; a body that cannot GLUES to the label. Asking the
 * flat-length question first narrows the dependence on the source line shape but does not remove it: a
 * collection whose cascade answers a non-breaking mode and which the renderer then breaks on width still takes
 * two passes (`unit.WrapFlatSourceFixedPointTest`). Fan-out flags: `@:fmt(flatChildOpt('A=B', ...))` writes
 * the body's element, when the flat gate fires, with a `Reflect.copy(opt)` whose `ifBody`/`elseBody`/`forBody`
 * are overridden by `expressionCase` itself, so nested control flow inherits the case body's shape choice
 * without touching the `expressionIfBody` knobs `HxIfExpr` reads. `@:fmt(propagateExprPosition)` sets
 * `_inExprPosition = true` on an always-copy, so a case nested in another case's body picks the
 * expression-position `expressionCase` policy. `@:fmt(refuseFlatOnComplexExpr)` AND-s the generated
 * `caseBodyRefusesFlat` predicate into the flat gate: an `A && B` / `A || B` body refuses inline.
 * `@:fmt(refuseGlueOnControlFlowRoot)` gates the `FitLine` path: a body that cannot render flat AND whose
 * single statement is keyword-led control flow takes the BREAK shape — glued, its `else if` / `} while` /
 * `catch` continuation lines would render at the head's indent and read as if they had left the branch.
 */
@:peg
typedef HxCaseBranch = {
	@:sep(',') @:trail(':') @:fmt(wrapRules('casePatternWrap'), beforeNewlineSlotFirst, captureTrailComment) var patterns: Array<HxCasePattern>;
	@:trivia @:tryparse @:fmt(nestBody, bodyPolicy('caseBody', 'expressionCase'),
		flatChildOpt('ifBody=expressionCase', 'elseBody=expressionCase', 'forBody=expressionCase'), propagateExprPosition,
		clearExprPositionNonTail, refuseFlatOnComplexExpr, refuseGlueOnControlFlowRoot) var body: Array<HxStatement>;
};

package anyparse.grammar.haxe;

/**
 * Grammar for the `default:` branch body inside a switch statement. The `default` keyword is
 * consumed at the enum-branch level (`@:kw('default')` on the `DefaultBranch` ctor in
 * `HxSwitchCase`); this typedef describes the colon (`@:lead(':')` on `stmts`) and the body.
 *
 * The body uses `@:tryparse` to force try-parse termination even though `stmts` is the last
 * (and only) field: without it the last-field heuristic in `emitStarFieldSteps` would select
 * EOF mode and attempt to consume past the next `case` / `default` / `}` token. Try-parse
 * terminates cleanly because none of those tokens parse as an `HxStatement`.
 * `@:fmt(nestBody)` wraps the body Doc in an extra indent level, so statements drop onto their
 * own line below the `default:` header.
 *
 * Every layout flag mirrors `HxCaseBranch.body`, whose doc holds the contracts:
 * `@:fmt(bodyPolicy('caseBody', 'expressionCase'))` — single-stmt flat emission when the body
 * has no leading / orphan-trailing trivia AND either flag is `Same` OR either flag is `Keep`
 * and the source had the stmt on the same line as `:`; `caseBody` defaults to `Next`,
 * `expressionCase` to `Keep`, so an author-written `default: foo();` round-trips
 * byte-identically, and `FitLine` routes the same single-stmt eligibility to the deferred
 * `_fitCase` layout and `anyparse.format.BodyFit.fitLineLayout`.
 * `@:fmt(flatChildOpt('A=B', ...))` — when the flat gate fires, the body's element is written
 * with a `Reflect.copy(opt)` whose listed fields are overridden by the named sibling fields,
 * so nested control-flow inside a flat default body picks expression-position policy.
 * `@:fmt(propagateExprPosition)` — the runtime always-copy sets `_wo._inExprPosition = true`
 * so the dual-flag flat-gate in any descendant case body picks `expressionCase`; a
 * statement-position default body keeps `caseBody`. `@:fmt(refuseFlatOnComplexExpr)` — the
 * plugin-supplied `WriteOptions.caseBodyRefusesFlat` adapter AND-s into the runtime flat-gate
 * so a `default: A || B;` body refuses inline. `@:fmt(refuseGlueOnControlFlowRoot)` — a
 * `FitLine` body that cannot render flat and holds a single keyword-led control-flow
 * statement goes BELOW the `default:` label instead of gluing onto it.
 */
@:peg
typedef HxDefaultBranch = {
	@:lead(':') @:trivia @:tryparse @:fmt(nestBody, bodyPolicy('caseBody', 'expressionCase'),
		flatChildOpt('ifBody=expressionCase', 'elseBody=expressionCase', 'forBody=expressionCase'), propagateExprPosition,
		clearExprPositionNonTail, refuseFlatOnComplexExpr, refuseGlueOnControlFlowRoot) var stmts: Array<HxStatement>;
};

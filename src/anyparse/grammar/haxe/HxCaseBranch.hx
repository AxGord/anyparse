package anyparse.grammar.haxe;

/**
 * Grammar for a single `case pattern: body` branch inside a switch.
 *
 * The `case` keyword is consumed at the enum-branch level
 * (`@:kw('case')` on the `CaseBranch` ctor in `HxSwitchCase`).
 * This typedef describes the remainder: a comma-separated pattern
 * list followed by a colon, then zero or more body statements.
 *
 * `patterns` is a `@:sep(',') @:trail(':')` Star of `HxCasePattern`
 * — the same Star+sep+trail shape as `HxFnDecl.typeParams`. A single
 * `case A:` is a one-element list; `case A, B, C:` (Haxe multi-value
 * case) is the multi-element form. Each element's `expr` parses as
 * `HxExpr` — identifiers, literals, and constructor-like patterns
 * (`Foo(x, y)` parses as a `Call` expression) all work without new
 * grammar types.
 *
 * The element type widened from `HxExpr` to `HxCasePattern` to carry
 * an optional `if (cond)` guard (`case P if (c):`). Only the element
 * type changes; the Star's `@:sep(',') @:trail(':')` shape is
 * unchanged, so no `Lowering` constraint is touched. Haxe binds one
 * guard to the whole list, so it attaches to the last parsed element
 * and round-trips byte-identically. See `HxCasePattern` for the
 * element-wrap rationale. Full pattern matching (extractors) is
 * future work.
 *
 * `@:fmt(wrapRules('casePatternWrap'))` (slice ω-casepattern-wrap-ingest)
 * routes the comma-separated pattern list through `WrapList.emit` with
 * the `casePatternWrap` cascade (fork-mirror of `wrapping.casePattern`):
 * single/double patterns stay flat (`NoWrap`), three-or-more pack
 * Wadler-style via `FillLine`, overflow also fills. The Star has no
 * `@:lead`, so `WrapList` derives `open=''`/`close=':'`/`sep=','` — the
 * first pattern stays inline after the upstream `case ` keyword and the
 * `:` glues to the last pattern.
 *
 * `@:fmt(beforeNewlineSlotFirst)` (slice ω-casepattern-keep) opts this
 * FIRST field into the source-newline-before capture channel. Paired
 * with `@:fmt(forwardNewlineForBody)` on the parent `HxSwitchCase.
 * CaseBranch` ctor (which omits the post-`case` `skipWs`), the field's
 * pre-field `collectTrivia` scans the `case`→pattern gap and records
 * `newlineBefore` onto the synth `patternsBeforeNewline:Bool` slot. The
 * writer's struct-Star emit reads the slot and, when `opt.leftCurly ==
 * Next` (the `lineEnds.leftCurly: before`/`both` configs), wraps the
 * pattern Doc in `_dn(_cols, _dc([_dhl, …]))` so `case\n\t{pattern}`
 * round-trips verbatim. Byte-inert otherwise: `leftCurly == Same` and
 * absent source newline (`case {pattern}`) both keep the pattern glued
 * to the upstream `case ` keyword.
 *
 * The body uses `@:tryparse` to force try-parse termination on the
 * last field (D49). The try-parse loop breaks when the next token
 * is `case`, `default`, or `}` — none of which parse as an
 * `HxStatement`.
 *
 * `@:fmt(nestBody)` makes the writer wrap the body Doc in an extra
 * indent level, so statements drop onto their own line below the
 * `case pattern:` header at body-indent instead of inline.
 *
 * `@:fmt(bodyPolicy('caseBody', 'expressionCase'))` (ω-case-body-policy
 * + ω-case-body-keep + ω-expression-case-keep-default) exposes the
 * dual `WriteOptions` knobs that gate single-stmt-flat emission. The
 * writer skips the `nestBody` indent and emits `case X: foo();` flat
 * when the body has exactly one statement with no leading or
 * orphan-trailing comments AND either:
 *  - either flag is `Same` (override — always flatten); or
 *  - either flag is `Keep` and `Trivial<T>.newlineBefore` of the body's
 *    first element is `false` (preserve same-line source shape).
 * `caseBody` defaults to `Next`; `expressionCase` defaults to `Keep`
 * (so author-written `case X: foo();` round-trips byte-identically).
 * Multi-stmt bodies keep the multiline `nestBody` shape regardless.
 *
 * `@:fmt(flatChildOpt('A=B', ...))` (ω-expression-case-flat-fanout) opts
 * the body's child writer call into a copy-on-flat opt-fanout: when the
 * runtime flat gate fires, the body's element is written with a
 * `Reflect.copy(opt)` whose listed fields are overridden by the named
 * sibling fields. For Haxe, this swaps `ifBody`/`elseBody`/`forBody` for
 * `expressionCase` itself — when the case body is flattened, the inner
 * control-flow inherits the same shape choice the user picked for the
 * case body (`Same` → force inline, `Keep` → preserve source). Using
 * `expressionCase` as the swap source instead of the separate
 * `expressionIfBody`/`expressionElseBody`/`expressionForBody` knobs
 * avoids interfering with `HxIfExpr.thenBranch`/`HxIfExpr.elseBranch`
 * (which read those knobs directly for `var x = if (a) b else c` style
 * literals — `fitline_arrow_body_if.hxtest` would otherwise regress).
 * The fanout propagates through subsequent recursive writer calls (since
 * the copy is passed as `opt` to the child) — block-bodied descendants
 * reset naturally because their wrap policies are not gated on these
 * knobs.
 *
 * `@:fmt(propagateExprPosition)` (ω-issue-423-mech-a) flips the
 * runtime `_writerOpt` from a flat-only copy to an always-copy whose
 * `_inExprPosition` field is set to `true` unconditionally. The dual-
 * flag `bodyPolicy('caseBody', 'expressionCase')` flat-gate consults
 * `opt._inExprPosition` at runtime: descendants of a case body see
 * `true` and their case-body sites pick the expression-position
 * `expressionCase` policy (default `Keep`, flatten on same-line
 * source); top-level statement-position case bodies see `false` and
 * pick the statement-position `caseBody` policy (default `Next`,
 * break). Mirrors fork's `isReturnExpression` walk-up heuristic in
 * `MarkSameLine.markCase` — a case nested in another case's body is
 * treated as expression-position.
 *
 * `@:fmt(refuseFlatOnComplexExpr)` (ω-issue-423-mech-b) adds a body-
 * shape AND-clause to the runtime flat-gate via the plugin-supplied
 * `WriteOptions.caseBodyRefusesFlat` adapter (Haxe wires it to
 * `HxExprUtil.refusesCaseFlat`). A case body whose single statement
 * is `A && B` or `A || B` refuses inline regardless of the dual flat-
 * gate's verdict, so `case PRESSED: A || B;` breaks even at
 * expression-position where `expressionCase=Keep` + same-line source
 * would otherwise flatten. Empirical scope (probed against fork CLI)
 * is just the logical operators — every other binop, ternary, and
 * assignment variant nests hierarchically in fork's token tree and
 * stays inline. Mirrors fork's `markExpressionCase` body-shape check
 * (`dblDot.children.length == 2 && second.tok != CommentLine`).
 */
@:peg
typedef HxCaseBranch = {
	@:sep(',') @:trail(':') @:fmt(wrapRules('casePatternWrap'), beforeNewlineSlotFirst) var patterns:Array<HxCasePattern>;
	@:trivia @:tryparse @:fmt(
		nestBody, bodyPolicy('caseBody', 'expressionCase'),
		flatChildOpt('ifBody=expressionCase', 'elseBody=expressionCase', 'forBody=expressionCase'),
		propagateExprPosition, refuseFlatOnComplexExpr
	) var body:Array<HxStatement>;
};

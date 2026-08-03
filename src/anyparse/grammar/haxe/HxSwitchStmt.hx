package anyparse.grammar.haxe;

/**
 * Grammar for a switch statement.
 *
 * Shape: `switch (expr) { case ...: ... default: ... }`.
 *
 * The `switch` keyword is consumed at the enum-branch level
 * (`@:kw('switch')` on the `SwitchStmt` ctor in `HxStatement`).
 * This typedef describes the remainder: a parenthesised subject
 * expression and a brace-delimited list of case branches.
 *
 * The cases array uses close-peek termination on `}` — the loop
 * terminates when the closing brace is peeked, before trying to
 * parse the next `HxSwitchCase`. Individual case bodies use
 * `@:tryparse` termination (see `HxCaseBranch` and
 * `HxDefaultBranch`).
 *
 * `@:trivia` on `cases` makes every element a `Trivial<HxSwitchCaseT>`
 * in Trivia mode so own-line comments immediately before `case` /
 * `default` survive round-trip. Inside-body comments (between `case X:`
 * and the first statement) need a separate `@:trivia` on
 * `HxCaseBranch.body` / `HxDefaultBranch.stmts` — those are `@:tryparse`
 * Stars and depend on the tryparse + trivia Lowering path. Transitively
 * marks `HxSwitchCase` / `HxCaseBranch` / `HxDefaultBranch` as trivia-
 * bearing via `TriviaAnalysis`'s fixed-point closure, triggering `*T`
 * synthesis in `TriviaTypeSynth`.
 *
 * `@:fmt(indentCaseLabels)` (ω-indent-case-labels) gates the inner-
 * indent wrap that `triviaBlockStarExpr` normally adds around the
 * cases body — when `opt.indentCaseLabels` is `false` the labels and
 * their (still-`nestBody`-wrapped) bodies render flush with the
 * `switch` keyword instead of one level inside the braces.
 *
 * `@:fmt(leftCurly('blockLeftCurly'))` (slices ω-switch-leftCurly +
 * ω-blockcurly-broader) routes the space before the cases-block
 * opening `{` through `leftCurlySeparator`, reading the per-construct
 * `opt.blockLeftCurly` knob — preseeded by the loader from global
 * `lineEnds.leftCurly` and overridable via
 * `lineEnds.blockCurly.leftCurly`. `Same` keeps the cuddled
 * `switch (e) {`, `Next` produces Allman-style `switch (e)\n{` at the
 * surrounding indent. Same Star-with-`@:lead('{') @:trail('}')
 * @:trivia` mechanism as `HxStatement.BlockStmt` / `HxExpr.BlockExpr`;
 * `HxClassDecl.members` still uses bare `leftCurly` because class/
 * interface/abstract member braces are not Block-category in fork's
 * `detectCurlyPolicy`.
 *
 * `@:fmt(caseSiblingSymmetry('caseBody', 'expressionCase'))`
 * (ω-case-sibling-symmetry) opts this Star into the per-SWITCH placement
 * verdict: a widest-sibling pre-pass measures every element's flat width
 * and hands the maximum to all of them, so if one case body takes the
 * width-driven break they all do. The two names are the statement- and
 * expression-position body policies whose `FitLine` value arms it; under
 * every other policy the Star behaves exactly as before. See
 * `WriterLowering.caseSiblingWidthProbeExpr` for what does and does not
 * count as a trigger.
 *
 * `#if` INTERACTS ONE-DIRECTIONALLY, by construction. A conditional case
 * region projects as a single `HxSwitchCase.Conditional` /
 * `CondSpliceCase` element whose Doc carries directive hardlines, so its
 * `WrapList.flatLength` is `-1`. A `-1` element contributes nothing to
 * the maximum but still receives the verdict — so a `#if`-guarded case
 * FOLLOWS a plain sibling's break (probed: it moves down with the rest),
 * and can never LEAD one (probed: a switch whose only over-wide body sits
 * inside `#if` keeps the mixed shape). Making a conditional region able
 * to trigger needs its inner cases measured through the directive lines,
 * which is a separate slice; the current behaviour is safe in the sense
 * that it never spreads a switch that nothing else spread.
 */
@:peg
typedef HxSwitchStmt = {
	@:lead('(') @:trail(')') @:fmt(switchCondParensInsideOpen, switchCondParensInsideClose, switchSubjectNoWrap, switchSubjectParensStrip) var expr: HxExpr;
	@:fmt(leftCurly('blockLeftCurly'), emptyCurlyBreak('blockEmptyCurly'), rightCurly('blockRightCurly'), indentCaseLabels,
		caseSiblingSymmetry('caseBody', 'expressionCase')) @:lead('{') @:trail('}') @:trivia var cases: Array<HxSwitchCase>;
};

package anyparse.grammar.haxe;

/**
 * Grammar for a switch statement: `switch (expr) { case ...: ... default: ... }`. The
 * `switch` keyword is consumed at the enum-branch level (`@:kw('switch')` on the
 * `SwitchStmt` ctor in `HxStatement`); this typedef describes the parenthesised subject
 * expression and the brace-delimited list of case branches. `cases` uses close-peek
 * termination on `}`; individual case bodies use `@:tryparse` termination (see
 * `HxCaseBranch` and `HxDefaultBranch`).
 *
 * `@:trivia` on `cases` makes every element a `Trivial<HxSwitchCaseT>` in Trivia mode so
 * own-line comments immediately before `case` / `default` survive round-trip; inside-body
 * comments need the separate `@:trivia` on `HxCaseBranch.body` / `HxDefaultBranch.stmts`.
 *
 * `@:fmt(indentCaseLabels)` (ω-indent-case-labels) gates the inner-indent wrap that
 * `triviaBlockStarExpr` normally adds around the cases body — when `opt.indentCaseLabels` is
 * `false` the labels and their (still-`nestBody`-wrapped) bodies render flush with the
 * `switch` keyword. `@:fmt(leftCurly('blockLeftCurly'))` routes the space before the
 * cases-block `{` through `leftCurlySeparator`, reading the per-construct `opt.blockLeftCurly`
 * knob (preseeded from global `lineEnds.leftCurly`, overridable via
 * `lineEnds.blockCurly.leftCurly`): `Same` keeps `switch (e) {`, `Next` produces Allman-style
 * `switch (e)\n{`. The same mechanism as `HxStatement.BlockStmt` / `HxExpr.BlockExpr`.
 *
 * Each case body answers `caseBody` / `expressionCase` for itself: a body below its label
 * says nothing about its siblings.
 */
@:peg
typedef HxSwitchStmt = {
	@:lead('(') @:trail(')') @:fmt(switchCondParensInsideOpen, switchCondParensInsideClose, switchSubjectNoWrap, switchSubjectParensStrip,
		suppressComplexItems) var expr: HxExpr;
	@:fmt(leftCurly('blockLeftCurly'), emptyCurlyBreak('blockEmptyCurly'), rightCurly('blockRightCurly'), indentCaseLabels) @:lead('{') @:trail('}') @:trivia var cases: Array<HxSwitchCase>;
};

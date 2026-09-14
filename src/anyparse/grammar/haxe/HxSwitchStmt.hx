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
 * `@:fmt(caseSiblingSymmetry('caseBody', 'expressionCase'))` (ω-case-sibling-symmetry) opts
 * this Star into the per-SWITCH placement verdict: if ANY case body of this switch renders
 * on the line(s) BELOW its label, every case body does. Two channels reach that verdict — a
 * STRUCTURAL one (the generated `caseUnitStructuralBreak_HxSwitchCase` predicate flags a unit
 * whose body is below its label at any budget) and a WIDTH one (a widest-sibling pre-pass
 * hands the maximum flat width to every unit). The two names are the statement- and
 * expression-position body policies whose `FitLine` value arms both; under every other
 * policy the Star behaves as before. See `WriterBlankLowering.caseSiblingWidthProbeExpr` for
 * what counts as a trigger. A `#if` region leads as well as follows (ω-if-leader-case-symmetry):
 * the generated `caseSiblingUnits_HxSwitchCase` flattener expands the region into its inner
 * case ELEMENTS across every branch (branches are ALTERNATIVES, so the maximum over all of
 * them is the conservative trigger), recursively for nested regions; under the DEFAULT
 * `conditionalPolicy: aligned` those cases render at the same indent as this switch's own,
 * so the widths stay comparable — under `Increase` / `Decrease` a region can still come out
 * asymmetric, a limitation carried forward. `CondSpliceCase` stays ONE unit and LEADS the
 * spread. `HxConditionalCase.body` / `elseBody` and `HxElseifCase.body` are deliberately NOT
 * opted in: the element-opt width stamp is always written and never inherited, so an
 * opted-in inner Star would overwrite this switch's verdict for the cases inside the region.
 */
@:peg
typedef HxSwitchStmt = {
	@:lead('(') @:trail(')') @:fmt(switchCondParensInsideOpen, switchCondParensInsideClose, switchSubjectNoWrap, switchSubjectParensStrip,
		suppressComplexItems) var expr: HxExpr;
	@:fmt(leftCurly('blockLeftCurly'), emptyCurlyBreak('blockEmptyCurly'), rightCurly('blockRightCurly'), indentCaseLabels,
		caseSiblingSymmetry('caseBody', 'expressionCase')) @:lead('{') @:trail('}') @:trivia var cases: Array<HxSwitchCase>;
};

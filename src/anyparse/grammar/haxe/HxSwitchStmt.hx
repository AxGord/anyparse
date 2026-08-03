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
 * `#if` NOW LEADS AS WELL AS FOLLOWS (ω-if-leader-case-symmetry). A
 * conditional case region projects as a single `HxSwitchCase.Conditional`
 * element whose own Doc carries directive hardlines, so measured whole its
 * `WrapList.flatLength` is `-1` — it received the verdict but could never
 * produce one. So the pre-pass does not measure it whole: the generated
 * `caseSiblingUnits_HxSwitchCase` flattener expands the region into its
 * inner case ELEMENTS and each one is measured on its own, so an over-wide
 * `#if`-guarded body now LEADS the spread as well as follows it.
 *
 * The units are taken across the `#if` / `#elseif` / `#else` branches
 * because branches are ALTERNATIVES — only one of them is ever compiled —
 * so the maximum over all of them is the conservative trigger, and the one
 * emitted file serves every compilation variant. A region nested inside a
 * region flattens recursively: case-scope conditionals do not lift indent
 * (`HxConditionalCase.body` carries only `padLeading, padTrailing,
 * conditionalBodyIndent`, never `alignedNestedIncrease`), so their cases
 * render at the SAME indent as this switch's own and the widths stay
 * comparable.
 *
 * Two shapes still contribute nothing. `CondSpliceCase` — a region that
 * splits a case's LABELS from the body they share after `#end` — keeps
 * those labels byte-verbatim in an `HxCondSpliceRaw`, so it has no inner
 * case list to measure. And an inner case that cannot itself render flat (a
 * glued, multi-statement or refused body) is excluded on exactly the terms
 * above, the same as a top-level sibling.
 *
 * `HxConditionalCase.body` / `elseBody` and `HxElseifCase.body` are
 * deliberately NOT opted into `caseSiblingSymmetry`, against a literal
 * reading of "every case list coordinates". The element-opt width stamp is
 * ALWAYS written and never inherited, so an opted-in inner Star would run
 * its OWN pre-pass and overwrite this switch's verdict for the cases inside
 * the region — fragmenting one switch into per-region coordination. Leaving
 * them out is what lets the outer verdict flow through, so the switch
 * coordinates as ONE switch. `HxCondSpliceSwitchOpen.cases` IS opted in for
 * the opposite reason: it is a ROOT case list with no enclosing coordinated
 * Star to inherit a verdict from.
 */
@:peg
typedef HxSwitchStmt = {
	@:lead('(') @:trail(')') @:fmt(switchCondParensInsideOpen, switchCondParensInsideClose, switchSubjectNoWrap, switchSubjectParensStrip) var expr: HxExpr;
	@:fmt(leftCurly('blockLeftCurly'), emptyCurlyBreak('blockEmptyCurly'), rightCurly('blockRightCurly'), indentCaseLabels,
		caseSiblingSymmetry('caseBody', 'expressionCase')) @:lead('{') @:trail('}') @:trivia var cases: Array<HxSwitchCase>;
};

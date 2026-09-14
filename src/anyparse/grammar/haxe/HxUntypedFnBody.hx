package anyparse.grammar.haxe;

/**
 * Inner shape for the `untyped { stmts }` body modifier shared by `HxFnBody.UntypedBlockBody`
 * (`function f():T untyped { … }`) and `HxStatement.UntypedBlockStmt` (`untyped { … }` block
 * statement, incl. `try untyped { … }`).
 *
 * The keyword `untyped` lives on the inner field — NOT on the outer enum branch — so the
 * outer ctor becomes a single-Ref Case 3 over `HxUntypedFnBody`. Branch-level
 * `@:fmt(bodyPolicy('untypedBody'))` on the outer ctor then wraps the entire `untyped { … }`
 * output via `bodyPolicyWrap`, which prepends the runtime-switched separator BEFORE the
 * `untyped` keyword: `Same` (default) cuddles after the function header, `Next` pushes
 * `untyped` onto its own line one indent step deeper. Mirrors haxe-formatter's `markUntyped`,
 * which applies `sameLine.untypedBody` to the gap before the keyword.
 *
 * The `block:HxFnBlock` Ref reuses the same Seq wrapper as `HxFnBody.BlockBody` so the inner
 * `{ stmts }` payload, brace policy, `@:trivia` capture and orphan-trivia synth slots are all
 * shared.
 *
 * Field-level `@:fmt(leftCurly('blockLeftCurly'))` routes the `untyped`→`{` gap through
 * `leftCurlySeparator`: `Same` (default) keeps the brace cuddled, `Next` drops it onto its own
 * line at the current indent. Reads `opt.blockLeftCurly` — the per-construct `Block` knob the
 * loader preseeds from global `lineEnds.leftCurly` and `lineEnds.blockCurly.leftCurly` overrides
 * — shared with the sister Block-category consumers (`HxFnDecl.body`, `HxStatement.BlockStmt`,
 * `HxExpr.BlockExpr`, `HxSwitchStmt.cases`, `HxSwitchStmtBare.cases`); member-Star bodies on
 * type decls still read bare `opt.leftCurly` (a separate sub-category in the fork's
 * `detectCurlyPolicy`).
 */
@:peg
typedef HxUntypedFnBody = {
	@:kw('untyped') @:fmt(leftCurly('blockLeftCurly')) var block: HxFnBlock;
}

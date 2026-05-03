package anyparse.grammar.haxe;

/**
 * Inner shape for the `untyped { stmts }` body modifier shared by
 * `HxFnBody.UntypedBlockBody` (`function f():T untyped { … }`) and
 * `HxStatement.UntypedBlockStmt` (`untyped { … }` block statement,
 * incl. `try untyped { … }`).
 *
 * The keyword `untyped` lives on the inner field — NOT on the outer
 * enum branch — so the outer ctor becomes a single-Ref Case 3 over
 * `HxUntypedFnBody`. Branch-level `@:fmt(bodyPolicy('untypedBody'))`
 * on the outer ctor then wraps the entire `untyped { … }` output via
 * `bodyPolicyWrap`, which prepends the runtime-switched separator
 * BEFORE the `untyped` keyword (the parent→untyped transition). The
 * wrap output structure is `[separator, untyped, leftCurlySep, {…}]`:
 *  - `Same` (default) → `[' ', untyped, leftCurlySep, {…}]` cuddles
 *    after the function header (`function f():T untyped { … }` when
 *    `leftCurly=Same`; with `leftCurly=Next` the brace drops onto its
 *    own line via the inner gap).
 *  - `Next` → `[Nest(_cols, [hardline, untyped, leftCurlySep, {…}])]`
 *    pushes `untyped` onto its own line at one indent step deeper
 *    (`function f():T\n\tuntyped { … }`).
 *
 * Mirrors haxe-formatter's `markUntyped` (MarkSameLine.hx:1024) which
 * applies `sameLine.untypedBody` to the gap before the `untyped`
 * keyword whenever the parent token is not a Block-typed `BrOpen`.
 *
 * The `block:HxFnBlock` Ref reuses the same Seq wrapper as
 * `HxFnBody.BlockBody` so the inner `{ stmts }` payload, brace policy,
 * `@:trivia` capture, and orphan-trivia synth slots are all shared.
 *
 * Field-level `@:fmt(leftCurly)` (slice ω-untyped-leftCurly) routes the
 * `untyped`→`{` gap through `leftCurlySeparator`: `Same` (default) →
 * `_dt(' ')` keeps the brace cuddled (`untyped { … }`), `Next` →
 * `_dhl()` drops the brace onto its own line at the current indent
 * (`untyped\n<indent>{ … }`). Mirrors haxe-formatter's
 * `lineEnds.leftCurly: both`/`before` Allman placement which is global
 * across all `{` opens — for `untyped { … }` this means the brace after
 * the `untyped` keyword breaks too. The bare flag (no knob name) reads
 * `opt.leftCurly`, the same global knob HxFnDecl.body, HxClassDecl, etc.
 * already consume.
 */
@:peg
typedef HxUntypedFnBody = {
	@:kw('untyped') @:fmt(leftCurly) var block:HxFnBlock;
}

package anyparse.grammar.haxe;

/**
 * Try-catch statement grammar (block-body form).
 *
 * Shape: `try body catch (name:Type) catchBody [catch ...]` where
 * `body` and each catch clause's `body` are full `HxStatement`s
 * (typically `BlockStmt`). Bare-expression bodies live on the
 * sibling ctor `HxStatement.TryCatchStmtBare` (typedef
 * `HxTryCatchStmtBare`) — see source-order disambiguation in
 * `HxStatement`.
 *
 * The `try` keyword is consumed at the enum-branch level
 * (`@:kw('try')` on the `TryCatchStmt` ctor in `HxStatement`).
 * This typedef describes the remainder: a statement body followed
 * by one or more catch clauses.
 *
 * The `catches` array uses `@:tryparse` termination (D49) — the
 * loop terminates when the next token fails to parse as
 * `HxCatchClause` (i.e. no `catch` keyword found). Without
 * `@:tryparse`, the last-field heuristic would select EOF mode.
 *
 * `@:fmt(bodyPolicy('tryBody'), kwPolicy('tryPolicy'))` on `body`
 * (ω-tryBody) wraps the `try`→body separator through
 * `WriterLowering.bodyPolicyWrap` in `kwOwnsInlineSpace` mode. The
 * `bodyPolicy('tryBody')` flag drives the body-placement axis at
 * runtime (Same/Next/FitLine/Keep). The `kwPolicy('tryPolicy')`
 * companion names the parent ctor's sibling `WhitespacePolicy` knob
 * — under the `Same` body layout, the inline gap routes through
 * `opt.tryPolicy` (After/Both → space, None/Before → empty) so
 * `tryPolicy=None` + `tryBody=Same` collapses to `try{…}` while
 * default `tryPolicy=After` + `tryBody=Same` keeps `try {…}`. The
 * parent Case 3's `subStructStartsWithBodyPolicy` strip predicate
 * still fires (kw-trail-space slot is null), so the kw-policy logic
 * is consolidated inside the wrap.
 *
 * `@:fmt(sameLine('sameLineCatch'), bareBodyBreaks)` on `catches`
 * makes the writer's separator between the body and the first catch,
 * and between consecutive catches, both runtime-switchable AND shape-
 * aware. The `sameLine('sameLineCatch')` flag drives policy: `Same`
 * → space (`} catch (…)`); `Next` → hardline (`}\ncatch (…)`). The
 * `bareBodyBreaks` companion (ω-tryBody-next-default + sameLineCatch-
 * shape-aware) forces a hardline before each catch whenever the
 * preceding body is non-block (e.g. `ExprStmt`), regardless of
 * `sameLineCatch`. Pairs with `tryBody=Next` default: a non-block
 * body breaks before via `bodyPolicy('tryBody')`, so the catch must
 * also break to keep the multi-line `try\n\tBARE;\ncatch (…)\n\tBARE;`
 * layout coherent. Block bodies fall through to the policy-driven
 * separator as before — `try { … } catch (…)` stays inline under
 * `sameLineCatch=Same`.
 *
 * `@:fmt(bodyPolicyOverride('UntypedBlockStmt', 'untypedBody'))` on
 * `body` (slice ω-untyped-body-stmt-override) flips the body-policy
 * flag from `tryBody` to `untypedBody` at runtime when the body is
 * `HxStatement.UntypedBlockStmt` (i.e. `try untyped { … }`). Mirrors
 * haxe-formatter's `markUntyped` rule: `sameLine.untypedBody` applies
 * to the gap before the `untyped` keyword whenever the parent token
 * is not a Block-typed `BrOpen`. The `try` body slot is non-block, so
 * `untypedBody=Next` (`try\n\tuntyped {…}`) wins over the default
 * `tryBody=Same` (`try untyped {…}`). Block-stmt Star context (e.g.
 * `{ untyped {…} }`) has no override and keeps the Star's `\n<indent>`
 * separator unchanged, so `untypedBody` stays inert there — matching
 * haxe-formatter's BrOpen-parent exception. Independently, the inner
 * `untyped`→`{` gap is governed by `HxUntypedFnBody.block`'s
 * `@:fmt(leftCurly)` (slice ω-untyped-leftCurly): under
 * `leftCurly=Next` the brace lands on its own line, so
 * `try untyped\n<indent>{…}` is reachable from `tryBody=Same` +
 * `leftCurly=Next` and full Allman `try\n<indent>untyped\n<indent>{…}`
 * from `untypedBody=Next` + `leftCurly=Next`.
 */
@:peg
typedef HxTryCatchStmt = {
	@:fmt(bodyPolicy('tryBody'), kwPolicy('tryPolicy'), bodyPolicyOverride('UntypedBlockStmt', 'untypedBody')) var body:HxStatement;
	@:trivia @:tryparse @:fmt(sameLine('sameLineCatch'), bareBodyBreaks) var catches:Array<HxCatchClause>;
};

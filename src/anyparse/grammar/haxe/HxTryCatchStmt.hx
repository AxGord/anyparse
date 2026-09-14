package anyparse.grammar.haxe;

/**
 * Try-catch statement grammar (block-body form): `try body catch (name:Type) catchBody
 * [catch ...]` where `body` and each catch clause's `body` are full `HxStatement`s;
 * bare-expression bodies live on the sibling ctor `HxStatement.TryCatchStmtBare`. The `try`
 * keyword is consumed at the enum-branch level. The `catches` Star uses `@:tryparse`
 * termination (D49) — without it the last-field heuristic would select EOF mode.
 *
 * `@:fmt(bodyPolicy('tryBody'), kwPolicy('tryPolicy'))` on `body` (ω-tryBody) wraps the
 * `try`→body separator through `WriterLowering.bodyPolicyWrap` in `kwOwnsInlineSpace` mode:
 * `bodyPolicy('tryBody')` drives the placement axis, and under the `Same` layout the inline
 * gap routes through `opt.tryPolicy` (After/Both → space, None/Before → empty) so
 * `tryPolicy=None` collapses to `try{…}`; the kw-policy logic is consolidated in the wrap.
 *
 * `@:fmt(sameLine('sameLineCatch'), bareBodyBreaks)` on `catches` makes the separator before
 * each catch runtime-switchable AND shape-aware: `Same` → space, `Next` → hardline, and
 * `bareBodyBreaks` forces a hardline whenever the preceding body is non-block regardless of
 * `sameLineCatch`, so a bare body breaks before AND after under the `tryBody=Next` default.
 *
 * `@:fmt(bodyPolicyOverride('UntypedBlockStmt', 'untypedBody'))` on `body` flips the
 * body-policy flag from `tryBody` to `untypedBody` at runtime for `try untyped { … }`
 * (haxe-formatter's `markUntyped`). `@:fmt(beforeNewlineSlotFirst)` on `body` extends the
 * `<field>BeforeNewline:Bool` synth slot to a FIRST Ref field, paired with
 * `@:fmt(forwardNewlineForBody)` on `HxStatement.TryCatchStmt` (Case 3 OMITS the post-kw
 * `skipWs(ctx)` so the inner first-field's `collectTrivia` captures `newlineBefore`), which
 * the writer forwards into `bodyPolicyWrap` for the `Keep` dispatch.
 *
 * omega-try-brace-symmetry: `@:fmt(tryBraceSymmetry('catches', 'BlockStmt'))` on `body` and
 * `@:fmt(tryCatchBraceSymmetry('body', 'BlockStmt'))` on `catches` substitute both halves
 * under ONE group verdict, so the try body and every catch body are braced together or bare
 * together — the try/catch twin of `SingleStmtBraces` gate 7; `@:fmt(tryDeBrace)` on both
 * opts this STATEMENT form into the de-brace direction. Haxe rejects a `;` in front of
 * `catch`, so every body but the last renders with its `;` slot cleared, `ExprStmt` only.
 *
 * `@:fmt(constructFitGroup('body', 'catches'))` on the TYPEDEF splices the whole construct
 * into one `BodyGroup`, the shape the condWrap path builds for `if` / `for` / `while` out of
 * their CONDITION field; without it each seam answered the width question on its own line,
 * squeezing a de-braced `try f(a, b) catch (e) g();` into breaking INSIDE the call.
 * `constructFitSep` on `catches` and `constructFitBody` on every body field make each seam
 * a SOFT line the group owns, so they break together into an if/else ladder.
 */
@:peg
@:fmt(constructFitGroup('body', 'catches'))
typedef HxTryCatchStmt = {
	@:trailOpt(';') @:fmt(bodyPolicy('tryBody'), kwPolicy('tryPolicy'), bodyPolicyOverride('UntypedBlockStmt', 'untypedBody'),
		beforeNewlineSlotFirst, constructFitBody, tryBraceSymmetry('catches', 'BlockStmt'), tryDeBrace) var body: HxStatement;
	@:trivia @:tryparse @:fmt(sameLine('sameLineCatch'), bareBodyBreaks('tryBody', 'catchBody'), constructFitSep,
		tryCatchBraceSymmetry('body', 'BlockStmt'), tryDeBrace) var catches: Array<HxCatchClause>;
};

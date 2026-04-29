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
 * `@:fmt(sameLine("sameLineCatch"))` on `catches` makes the writer's
 * separator between the body and the first catch, and between
 * consecutive catches, runtime-switchable: when the flag is `Same`
 * the separator is a plain space (`} catch (…)`); when `Next` it
 * becomes a hardline (`}\ncatch (…)`).
 */
@:peg
typedef HxTryCatchStmt = {
	@:fmt(bodyPolicy('tryBody'), kwPolicy('tryPolicy')) var body:HxStatement;
	@:trivia @:tryparse @:fmt(sameLine('sameLineCatch')) var catches:Array<HxCatchClause>;
};

package anyparse.grammar.haxe;

/**
 * Body shape on `HxFnExpr.body` — the expression-position sibling
 * of `HxFnBody`.
 *
 * Two forms are recognised:
 *  - `BlockBody(block:HxFnBlock)` — `{ stmts }` braced body.
 *    Reuses the same `HxFnBlock` Seq-typedef wrapper as
 *    `HxFnBody.BlockBody`, so the `@:trivia` orphan-comment slots
 *    and `{`-leading peek dispatch are identical.
 *  - `ExprBody(expr:HxExpr)` — single-expression body, e.g.
 *    `function (res) trace(res)`. Catch-all branch tried after
 *    the literal-led `BlockBody`.
 *
 * The key departure from `HxFnBody.ExprBody` is the absence of
 * `@:trail(';')`: in expression position the body is followed by
 * `,` or `)` (inside a Call args list) or by an outer terminator,
 * not by a semicolon. The fn-expression itself does not own the
 * statement terminator.
 *
 * `NoBody` (`;`-only) has no analogue here — anon-fn expressions
 * always carry a real body. Branch order matters for dispatch:
 * BlockBody → ExprBody. `BlockBody` is `{`-led tight dispatch;
 * `ExprBody` runs the full HxExpr parser only when the first
 * branch's peek fails. `HxFnBlock` is trivia-bearing, which
 * transitively makes this enum bearing — paired type
 * `HxFnExprBodyT` synthesised by `TriviaTypeSynth`.
 */
@:peg
enum HxFnExprBody {

	BlockBody(block:HxFnBlock);

	ExprBody(expr:HxExpr);
}

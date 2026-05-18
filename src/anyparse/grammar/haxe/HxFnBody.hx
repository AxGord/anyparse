package anyparse.grammar.haxe;

/**
 * Function-body shape on `HxFnDecl.body`.
 *
 * Four forms are recognised:
 *  - `UntypedBlockBody(body:HxUntypedFnBody)` — `untyped { stmts }` body
 *    with the `untyped` keyword as a pre-block modifier
 *    (`function f():Type untyped { body }`). Real Haxe sugar that
 *    wraps the entire body in an untyped block. The kw + `HxFnBlock`
 *    payload live inside the `HxUntypedFnBody` Seq wrapper so this
 *    branch is a single-Ref Case 3 with no own `@:kw`. Branch-level
 *    `@:fmt(bodyPolicy('untypedBody'))` (slice ω-untyped-body-policy)
 *    drives the parent→`untyped` separator via `bodyPolicyWrap`, which
 *    prepends the runtime-switched separator BEFORE the inner kw —
 *    `Same` (default) cuddles `function f():T untyped { … }`, `Next`
 *    pushes `untyped` to its own line. The parent `HxFnDecl.body`'s
 *    leftCurly Case 5 routes this ctor through `spacePrefixCtors` +
 *    `ctorHasBodyPolicy` (=> `_de()` separator), so the inner wrap is
 *    the sole source of the kw-leading transition. The `untyped`→`{`
 *    gap is governed independently by `HxUntypedFnBody.block`'s
 *    `@:fmt(leftCurly)` (slice ω-untyped-leftCurly): under
 *    `leftCurly=Next` the brace also drops onto its own line. Must
 *    appear before `BlockBody` so the inner `untyped` peek (via
 *    tryBranch rollback) fires before the bare-`{` dispatch.
 *  - `BlockBody(block:HxFnBlock)` — `{ stmts }` braced body. The
 *    `{`-leading peek that dispatches this branch lives on the
 *    `HxFnBlock.stmts` field; the brace policy (`@:fmt(leftCurly)`),
 *    the `@:trivia` capture, and the orphan-trivia trailing slots all
 *    sit inside the Seq-typedef wrapper (see `HxFnBlock`).
 *  - `NoBody` — `;` only. The shape of an interface method or
 *    `@:overload` stub: `function foo():Void;`. Dispatched by the
 *    `;` literal.
 *  - `ExprBody(expr:HxExpr)` — single-expression body, optionally
 *    terminated by `;`: `function foo() trace("hi");` OR
 *    `function foo() trace("hi")` with the `;` elided (e.g. as the
 *    last class member before `}`, or a top-level decl before EOF).
 *    Catch-all branch tried after the two literal-led siblings;
 *    `tryBranch`'s rollback ensures `BlockBody` (`{`-led) and `NoBody`
 *    (`;`-led) win on shared input. `@:trailOpt(';')` consumes the
 *    terminator when present and tracks its source presence — Haxe
 *    treats the `;` as optional here and the writer re-emits it
 *    byte-faithfully (single-Ref Alt `trailPresent` arg, mirror of
 *    `HxStatement.ExprStmt`). The kw→body separator is
 *    runtime-switchable via `@:fmt(bodyPolicy('functionBody'))`
 *    (slice ω-functionBody-policy) — `Next` (default) emits a
 *    hardline + Nest, `Same` emits a single space. The parent
 *    `HxFnDecl.body` field's Case 5 (Ref + `@:fmt(leftCurly)`)
 *    suppresses its fixed `_dt(' ')` for ctors carrying ctor-level
 *    `@:fmt(bodyPolicy(...))` so the wrap inside this branch's writer
 *    fully owns the kw-to-body separator.
 *
 * Branch order matters for dispatch: UntypedBlockBody → BlockBody →
 * NoBody → ExprBody. UntypedBlockBody dispatches via the inner
 * `HxUntypedFnBody`'s first-field `@:kw('untyped')` (peeked through
 * `tryBranch` rollback when input doesn't start with `untyped`); the
 * other three are tight first-char/keyword dispatches; ExprBody runs
 * the full HxExpr parser only when the preceding three fail.
 * `HxFnBlock` is trivia-bearing, which transitively makes this enum
 * bearing — paired type `HxFnBodyT` synthesised by `TriviaTypeSynth`.
 */
@:peg
enum HxFnBody {

	@:fmt(multilineCtor)
	UntypedBlockBody(body:HxUntypedFnBody);

	@:fmt(multilineCtor)
	BlockBody(block:HxFnBlock);

	@:lit(';')
	NoBody;

	@:trailOpt(';') @:fmt(bodyPolicy('functionBody'))
	ExprBody(expr:HxExpr);
}

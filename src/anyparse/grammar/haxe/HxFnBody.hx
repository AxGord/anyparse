package anyparse.grammar.haxe;

/**
 * Function-body shape on `HxFnDecl.body`.
 *
 * Four forms are recognised:
 *  - `UntypedBlockBody(block:HxFnBlock)` — `untyped { stmts }` body
 *    with the `untyped` keyword as a pre-block modifier
 *    (`function f():Type untyped { body }`). Real Haxe sugar that
 *    wraps the entire body in an untyped block. Reuses `HxFnBlock`
 *    verbatim for the `{ stmts }` payload; the `@:kw('untyped')`
 *    commit point distinguishes this branch from plain `BlockBody`.
 *    Must appear before `BlockBody` so the keyword commit fires
 *    before the bare-`{` dispatch. Slice ω-untyped-block-stmt-body
 *    targets `issue_362_untyped_body*` corpus fixtures.
 *  - `BlockBody(block:HxFnBlock)` — `{ stmts }` braced body. The
 *    `{`-leading peek that dispatches this branch lives on the
 *    `HxFnBlock.stmts` field; the brace policy (`@:fmt(leftCurly)`),
 *    the `@:trivia` capture, and the orphan-trivia trailing slots all
 *    sit inside the Seq-typedef wrapper (see `HxFnBlock`).
 *  - `NoBody` — `;` only. The shape of an interface method or
 *    `@:overload` stub: `function foo():Void;`. Dispatched by the
 *    `;` literal.
 *  - `ExprBody(expr:HxExpr)` — single-expression body terminated by
 *    `;`: `function foo() trace("hi");`. Catch-all branch tried after
 *    the two literal-led siblings; `tryBranch`'s rollback ensures
 *    `BlockBody` (`{`-led) and `NoBody` (`;`-led) win on shared input.
 *    `@:trail(';')` is non-optional — real Haxe requires the
 *    terminator after an expression body. The kw→body separator is
 *    runtime-switchable via `@:fmt(bodyPolicy('functionBody'))`
 *    (slice ω-functionBody-policy) — `Next` (default) emits a
 *    hardline + Nest, `Same` emits a single space. The parent
 *    `HxFnDecl.body` field's Case 5 (Ref + `@:fmt(leftCurly)`)
 *    suppresses its fixed `_dt(' ')` for ctors carrying ctor-level
 *    `@:fmt(bodyPolicy(...))` so the wrap inside this branch's writer
 *    fully owns the kw-to-body separator.
 *
 * Branch order matters for dispatch: UntypedBlockBody → BlockBody →
 * NoBody → ExprBody. The first three are tight first-char/keyword
 * dispatches; the fourth runs the full HxExpr parser only when the
 * preceding three fail. `HxFnBlock` is trivia-bearing, which
 * transitively makes this enum bearing — paired type `HxFnBodyT`
 * synthesised by `TriviaTypeSynth`.
 */
@:peg
enum HxFnBody {

	@:kw('untyped') @:fmt(multilineCtor)
	UntypedBlockBody(block:HxFnBlock);

	@:fmt(multilineCtor)
	BlockBody(block:HxFnBlock);

	@:lit(';')
	NoBody;

	@:trail(';') @:fmt(bodyPolicy('functionBody'))
	ExprBody(expr:HxExpr);
}

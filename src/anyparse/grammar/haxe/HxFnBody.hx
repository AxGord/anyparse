package anyparse.grammar.haxe;

/**
 * Function-body shape on `HxFnDecl.body`.
 *
 * Three forms are recognised:
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
 *    terminator after an expression body. The writer emits a leading
 *    space ahead of the expression via the parent field's
 *    `Type.enumConstructor` switch (see `HxFnDecl.body` and the
 *    `WriterLowering` Ref-with-`@:fmt(leftCurly)` path).
 *
 * Branch order matters for dispatch: BlockBody → NoBody → ExprBody.
 * The first two are tight first-char dispatches; the third runs the
 * full HxExpr parser only when the first two fail. `HxFnBlock` is
 * trivia-bearing, which transitively makes this enum bearing —
 * paired type `HxFnBodyT` synthesised by `TriviaTypeSynth`.
 */
@:peg
enum HxFnBody {

	BlockBody(block:HxFnBlock);

	@:lit(';')
	NoBody;

	@:trail(';')
	ExprBody(expr:HxExpr);
}

package anyparse.grammar.haxe;

/**
 * Function-body shape on `HxFnDecl.body`.
 *
 * Two forms are recognised:
 *  - `BlockBody(block:HxFnBlock)` — `{ stmts }` braced body. The
 *    `{`-leading peek that dispatches this branch lives on the
 *    `HxFnBlock.stmts` field; the brace policy (`@:fmt(leftCurly)`),
 *    the `@:trivia` capture, and the orphan-trivia trailing slots all
 *    sit inside the Seq-typedef wrapper (see `HxFnBlock`).
 *  - `NoBody` — `;` only. The shape of an interface method or
 *    `@:overload` stub: `function foo():Void;`. Dispatched by the
 *    `;` literal.
 *
 * The two branches' first literals (`{` from `HxFnBlock.stmts` for
 * `BlockBody`, `;` for `NoBody`) have no shared prefix, so declaration
 * order is irrelevant to dispatch. `HxFnBlock` is trivia-bearing, which
 * transitively makes this enum bearing — paired type `HxFnBodyT`
 * synthesised by `TriviaTypeSynth`.
 */
@:peg
enum HxFnBody {

	BlockBody(block:HxFnBlock);

	@:lit(';')
	NoBody;
}

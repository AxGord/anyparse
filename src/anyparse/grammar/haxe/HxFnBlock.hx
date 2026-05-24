package anyparse.grammar.haxe;

/**
 * `{ stmts }` payload of `HxFnBody.BlockBody`. A separate typedef so
 * the `@:trivia` Star sits inside a Seq rather than directly under an
 * Alt branch — the Seq path is the one `TriviaTypeSynth` synthesises
 * `<field>TrailingBlankBefore` / `<field>TrailingLeading` slots for,
 * which is what carries an orphan comment inside an otherwise empty
 * body through the parser into the writer. Alt-branch Stars have no
 * such slots, so collapsing this typedef into
 * `BlockBody(stmts:Array<HxStatement>)` directly drops orphan trivia
 * at parse time.
 *
 * The `@:fmt(leftCurly)` policy lives here too; the writer for
 * `HxFnDecl.body` emits the runtime BracePlacement separator before
 * the recursive call when the runtime branch is `BlockBody` (gated via
 * `Type.enumConstructor`), and the Star inside this typedef provides
 * the `{` lead and `}` trail with its own statement-trivia capture.
 *
 * Session 9 activation (BlockBody Star tail-relax refactor,
 * [[project-blockbody-star-tail-relax-debt]]): wired up
 * `@:sep(';', tailRelax, blockEnded('stmtNoSemi', sepStartsElement))`.
 * The `sepStartsElement` flag (Session 9 mechanism in `Lit.hx` +
 * `Lowering.hx`) resolves the EmptyStmt-vs-sep byte-ambiguity that
 * blocked Session 8's activation: when block-ended is TRUE the `;`
 * byte at pos ALWAYS starts the next element (HxStatement-semantics),
 * never a separator. So `;;` parses as 2 EmptyStmt, `{a;};b;` as
 * `[BlockStmt, EmptyStmt, ExprStmt]`. Without the flag the default
 * permissive-sep policy is sep-first and the `;` is greedily
 * consumed as a separator, losing one EmptyStmt.
 *
 * Per-stmt `@:trailOpt(';')` ownership remains in additive mode for
 * this session — the full BlockBody Star migration (move `;` from
 * per-stmt to BlockBody-level only) is a follow-up that deletes the
 * `stmtExprNoSemi` carve-outs in `HxExprUtil`.
 */
@:peg
@:fmt(multilineWhenFieldNonEmpty('stmts'))
typedef HxFnBlock = {
	@:fmt(emptyCurlyBreak, keepCurlyBlanks, rightCurlyAnonFnOverride('anonFunctionRightCurly'))
	@:lead('{') @:trail('}') @:trivia
	@:sep(';', tailRelax, blockEnded('stmtNoSemi', sepStartsElement))
	var stmts:Array<HxStatement>;
}

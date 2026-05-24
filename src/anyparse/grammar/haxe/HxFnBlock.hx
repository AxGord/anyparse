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
 * Session 8 activation attempt of option (b2) AST-shape adapter
 * ([[project-blockbody-star-session8-activation-attempt]]):
 * adding `@:sep(';', tailRelax, blockEnded('stmtNoSemi'))` here
 * collapsed `;;` from 2 EmptyStmt → 1 + sep-consumed (2 test
 * failures in `HxControlFlowSliceTest`). The Star's sep-first
 * branch competes with `EmptyStmt`'s `;` body — both match the
 * same byte and sep wins. Resolving requires `@:tryparse`-style
 * element-first speculation in the blockEnded Lowering branch
 * (out of session scope). Reverted to no `@:sep` so per-stmt
 * `@:trailOpt(';')` + `stmtExprNoSemi` carve-outs continue to be
 * the sole terminator mechanism.
 */
@:peg
@:fmt(multilineWhenFieldNonEmpty('stmts'))
typedef HxFnBlock = {
	@:fmt(emptyCurlyBreak, keepCurlyBlanks, rightCurlyAnonFnOverride('anonFunctionRightCurly')) @:lead('{') @:trail('}') @:trivia var stmts:Array<HxStatement>;
}

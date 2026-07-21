package anyparse.grammar.haxe;

/**
 * Statement-position token-splice conditional whose every branch OPENS a
 * block: `#if <cond> <fragment ending on '{'> [#elseif ...] [#else ...]
 * #end <shared statements> }`.
 *
 * Motivating source - `pony/ui/gui/BaseLayoutCore.hx:63`:
 *
 * ```haxe
 * #if (haxe_ver >= 4.10)
 * if (Std.isOfType(o, IWH)) {
 * #else
 * if (Std.is(o, IWH)) {
 * #end
 *     tasks.add();
 *     cast(o, IWH).wait(tasks.end);
 * } else load(o);
 * ```
 *
 * Neither branch is a balanced statement, so `HxStatement.Conditional`
 * fail-rewinds (its body Star cannot end on an unclosed `{`), and the
 * Haxe compiler never sees the problem because it lexes one branch away.
 * The parser must keep BOTH: `raw` captures the region byte-verbatim
 * through `#end`, `body` parses the shared statement list structurally,
 * and `body`'s `@:trail('}')` consumes the closer that the region's `{`
 * opened.
 *
 * `{raw, body}` - the `HxCondSpliceStmt` / `HxCondSpliceExpr` /
 * `HxCondSharedBodyMember` idiom - with the tail widened from one
 * statement to a Star because the shared continuation here is a whole
 * block body, not a single statement. The Star carries the same
 * `@:sep(';', tailRelax, blockEnded(...))` contract as
 * `HxStatement.BlockStmt.stmts`, which is precisely what it stands in
 * for.
 *
 * The `}` lives on `body` rather than on the owning ctor so the Star can
 * also carry `@:fmt(rightCurly)` - the flag that puts the closer on its
 * own line at the OUTER indent, the way `HxStatement.BlockStmt` emits its
 * own `}`. A ctor-level trail is emitted outside the Star's `nestBody`
 * indent scope and lands one level too deep. A `@:trail` field cannot
 * also be `@:tryparse` (WriterLowering rejects the pair); `body` is the
 * last field, so the trail is its termination mode.
 *
 * An `else` clause that follows the closing `}` - `} else load(o);`
 * above, and `} else { ... }` in `pony/flash/HaxeInit.hx:65` - is NOT a
 * field here. It reaches the enclosing statement Star as
 * `HxStatement.OrphanElseStmt`, the ctor that already exists for exactly
 * this situation (an `else` whose governing `if` head lives in another
 * lexical region). Adding an optional `else` field would duplicate it
 * and would have to re-answer the dangling-else question the orphan ctor
 * already answers.
 *
 * Dispatch: `HxStatement.CondSpliceBlockOpen` is tried BEFORE
 * `CondSpliceStmt`. That inversion of the usual "structured first"
 * ordering is safe only because `HxCondBlockOpenRaw` demands a `#else`
 * clause and a trailing `{` - see that type's doc for why the two ctors
 * are disjoint by construction, why `CondSpliceStmt` would otherwise
 * mis-bind these regions, and which live source forced the `#else` test.
 */
@:peg
typedef HxCondSpliceBlockOpen = {
	var raw: HxCondBlockOpenRaw;
	@:trail('}') @:trivia @:fmt(nestBody, rightCurly) @:sep(';', tailRelax, blockEnded('stmtNoSemi', sepStartsElement))
	var body: Array<HxStatement>;
}

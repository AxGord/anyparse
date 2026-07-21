package anyparse.grammar.haxe;

/**
 * Case-scope token-splice conditional: `#if <cond> <case labels> #end
 * <shared body>` -- a `#if` region that wraps ENTIRE `case` labels
 * (pattern list AND the terminating `:`) whose bodies live OUTSIDE the
 * region, shared by every compilation variant:
 *
 *     return switch ext(asset) {
 *         #if hxbitmini
 *         case ATLAS, BINATLAS:
 *         #else
 *         case ATLAS:
 *         #end
 *             if (name == null) throw ERROR_NAME_NOT_SET;
 *             var p: Null<Pair<Loader, Atlas>> = atlases[asset];
 *             p.b.get(name);
 *         case PNG, JPG: tiles[asset];
 *     };
 *
 * Live sources: `pony/heaps/HeapsAssets.hx:311` + `:336` (differing
 * ARITY between the branches) and `pony/magic/builder/InBuilder.hx:31`
 * (`case EBinop(OpIn, e1, e2):` vs `case EIn(e1, e2):`).
 *
 * Distinct from the already-supported `case #if A "x" #else "y" #end:`
 * form, where the region sits INSIDE the pattern list and the `:` is
 * outside -- that shape is a `HxCasePattern`-scope conditional and stays
 * structured. Here the `:` is inside the region and the branches differ
 * in pattern COUNT, so no case-list production can represent it.
 *
 * Field split -- `tail` (one mandatory statement) + `rest` (the
 * remainder) instead of a single `Array<HxStatement>` -- is the DISPATCH
 * DISCRIMINATOR, not an ergonomic choice. `HxSwitchCase.Conditional`
 * happily parses this region: its `Array<HxSwitchCase>` body sees
 * `case ATLAS, BINATLAS:` with an empty body, the `#else` arm sees
 * `case ATLAS:` with an empty body, and `#end` closes it -- leaving the
 * shared body orphaned at case-list scope, where the enclosing
 * `HxSwitchStmt.cases` Star breaks and the `}` trail throws (measured:
 * `HeapsAssets.hx` failed at `316:5`, the first shared-body statement).
 * A Star failing LATER in the parent cannot re-dispatch the earlier
 * element, so `CondSpliceCase` must be tried BEFORE `Conditional` -- and
 * then it needs a guard that fails on an ordinary whole-clause region
 * (`#if false case B: doB(); #end case D: doD();`). Requiring at least
 * one statement after `#end` is exactly that guard: at case-list scope
 * the only legal continuations are `case` / `default` / `#if` / `}`,
 * none of which parse as an `HxStatement`, so the mandatory `tail`
 * fail-rewinds the branch and `Conditional` keeps every balanced region
 * structured. `rest` then absorbs the remaining shared statements with
 * the same `@:trivia @:tryparse` termination `HxCaseBranch.body` uses,
 * and carries `@:fmt(padLeading)` so the writer breaks the line between
 * `tail` and `rest[0]` instead of gluing them (`...ERROR;var p...`).
 *
 * `raw` swallows the condition atom and every label through the closing
 * `#end` byte-verbatim (see `HxCondSpliceRaw`), so both compilation
 * variants survive a writer round-trip -- the whole point of the
 * `{raw, tail}` idiom.
 */
@:peg
typedef HxCondSpliceCase = {
	var raw: HxCondSpliceRaw;
	var tail: HxStatement;
	@:trivia @:tryparse @:fmt(padLeading) var rest: Array<HxStatement>;
}

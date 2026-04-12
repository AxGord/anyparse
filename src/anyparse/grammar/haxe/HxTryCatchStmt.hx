package anyparse.grammar.haxe;

/**
 * Try-catch statement grammar.
 *
 * Shape: `try body catch (name:Type) catchBody [catch ...]`.
 *
 * The `try` keyword is consumed at the enum-branch level
 * (`@:kw('try')` on the `TryCatchStmt` ctor in `HxStatement`).
 * This typedef describes the remainder: a bare statement body
 * followed by one or more catch clauses.
 *
 * The `catches` array uses `@:tryparse` termination (D49) — the
 * loop terminates when the next token fails to parse as
 * `HxCatchClause` (i.e. no `catch` keyword found). Without
 * `@:tryparse`, the last-field heuristic would select EOF mode.
 */
@:peg
typedef HxTryCatchStmt = {
	var body:HxStatement;
	@:tryparse var catches:Array<HxCatchClause>;
};

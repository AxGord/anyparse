package anyparse.grammar.haxe;

/**
 * Grammar for a switch statement.
 *
 * Shape: `switch (expr) { case ...: ... default: ... }`.
 *
 * The `switch` keyword is consumed at the enum-branch level
 * (`@:kw('switch')` on the `SwitchStmt` ctor in `HxStatement`).
 * This typedef describes the remainder: a parenthesised subject
 * expression and a brace-delimited list of case branches.
 *
 * The cases array uses close-peek termination on `}` — the loop
 * terminates when the closing brace is peeked, before trying to
 * parse the next `HxSwitchCase`. Individual case bodies use
 * `@:tryparse` termination (see `HxCaseBranch` and
 * `HxDefaultBranch`).
 *
 * `@:trivia` on `cases` makes every element a `Trivial<HxSwitchCaseT>`
 * in Trivia mode so own-line comments immediately before `case` /
 * `default` survive round-trip. Inside-body comments (between `case X:`
 * and the first statement) need a separate `@:trivia` on
 * `HxCaseBranch.body` / `HxDefaultBranch.stmts` — those are `@:tryparse`
 * Stars and depend on the tryparse + trivia Lowering path. Transitively
 * marks `HxSwitchCase` / `HxCaseBranch` / `HxDefaultBranch` as trivia-
 * bearing via `TriviaAnalysis`'s fixed-point closure, triggering `*T`
 * synthesis in `TriviaTypeSynth`.
 */
@:peg
typedef HxSwitchStmt = {
	@:lead('(') @:trail(')') var expr:HxExpr;
	@:lead('{') @:trail('}') @:trivia var cases:Array<HxSwitchCase>;
};

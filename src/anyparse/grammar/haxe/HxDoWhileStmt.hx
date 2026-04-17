package anyparse.grammar.haxe;

/**
 * Do-while loop grammar.
 *
 * Shape: `do body while (cond);`.
 *
 * The `do` keyword and trailing `;` are consumed at the enum-branch
 * level (`@:kw('do') @:trail(';')` on the `DoWhileStmt` ctor in
 * `HxStatement`). This typedef describes the remainder: a bare
 * statement body followed by a `while` keyword with a parenthesised
 * condition.
 *
 * The `cond` field combines `@:kw('while')` and `@:lead('(')` on the
 * same field — both are emitted sequentially (D50). The `@:trail(')')`
 * closes the parenthesised condition.
 *
 * `@:sameLine("sameLineDoWhile")` on `cond` makes the writer's
 * separator between the body and `while` runtime-switchable: when the
 * flag is true the separator is a plain space (`} while (…);`); when
 * false it becomes a hardline (`}\nwhile (…);`).
 */
@:peg
typedef HxDoWhileStmt = {
	var body:HxStatement;
	@:kw('while') @:lead('(') @:trail(')') @:sameLine('sameLineDoWhile') var cond:HxExpr;
};

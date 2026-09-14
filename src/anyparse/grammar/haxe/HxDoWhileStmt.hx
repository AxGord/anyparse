package anyparse.grammar.haxe;

/**
 * Do-while loop grammar: `do body while (cond);`.
 *
 * The `do` keyword and trailing `;` are consumed at the enum-branch level (`@:kw('do')
 * @:trail(';')` on the `DoWhileStmt` ctor in `HxStatement`); this typedef describes the
 * remainder: a body (`HxDoWhileBody` — block / nested do-while / bare expr) followed by a
 * `while` keyword with a parenthesised condition. `@:kw('while')` and `@:lead('(')` on the
 * same field are emitted sequentially (D50); `@:trail(')')` closes the condition.
 *
 * `@:fmt(sameLine("sameLineDoWhile"))` on `cond` makes the separator between the body and
 * `while` runtime-switchable: a plain space (`} while (…);`) when the flag is on, a hardline
 * otherwise.
 *
 * `@:fmt(bodyPolicy("doBody"))` on `body` places a non-block body relative to `do` — same
 * line, always next line, or fit-line (ψ₅). `@:fmt(dropSingleStmtBraces)` (ω-single-stmt-braces)
 * maps a single-`ExprStmt` `BlockBody` onto a bare `ExprBody` when `opt.dropSingleStmtBraces`
 * is set (`do { x(); } while (c);` → `do x() while (c);`, no `;` before `while` — modern Haxe
 * rejects it there) — see `anyparse.format.SingleStmtBraces.unwrapDoBody`. Block bodies always
 * take a single space regardless of the policy: the `{` carries its own layout via `blockBody`.
 *
 * `@:fmt(loopBodyIfElseNext(...))` is the loop-shape gate the `for` / `while` bodies carry:
 * when `sameLine.loopBodyIfElseNext` is on and the body is an `if` that owns an `else`, the
 * placement is replaced by `next` so the `else` stops sitting at the `do`'s own indent. The
 * body arrives wrapped as `ExprBody(IfExpr(…))` — hence the fourth argument, the ctor
 * `LoopBodyShape.isIfWithElse` unwraps before probing.
 *
 * Field-level `@:trailOpt(';')` covers a nested do-while: in `do do x; while(a); while(b);`
 * the outer body is `InnerDoWhile(inner)` and the `;` after the inner `)` is consumed at this
 * slot.
 */
@:peg
typedef HxDoWhileStmt = {
	@:trailOpt(';') @:fmt(bodyPolicy('doBody'), dropSingleStmtBraces,
		loopBodyIfElseNext('loopBodyIfElseNext', 'IfExpr', 'elseBranch', 'ExprBody')) var body: HxDoWhileBody;
	@:kw('while') @:lead('(') @:trail(')')
	@:fmt(sameLine('sameLineDoWhile'), whilePolicy, whileCondParensInsideOpen, whileCondParensInsideClose)
	var cond: HxExpr;
};

package anyparse.grammar.haxe;

/**
 * Do-while loop grammar.
 *
 * Shape: `do body while (cond);`.
 *
 * The `do` keyword and trailing `;` are consumed at the enum-branch
 * level (`@:kw('do') @:trail(';')` on the `DoWhileStmt` ctor in
 * `HxStatement`). This typedef describes the remainder: a body
 * (`HxDoWhileBody` alt-enum — block / nested do-while / bare expr)
 * followed by a `while` keyword with a parenthesised condition.
 *
 * The `cond` field combines `@:kw('while')` and `@:lead('(')` on the
 * same field — both are emitted sequentially (D50). The `@:trail(')')`
 * closes the parenthesised condition.
 *
 * `@:fmt(sameLine("sameLineDoWhile"))` on `cond` makes the writer's
 * separator between the body and `while` runtime-switchable: when the
 * flag is true the separator is a plain space (`} while (…);`); when
 * false it becomes a hardline (`}\nwhile (…);`).
 *
 * `@:fmt(bodyPolicy("doBody"))` on `body` controls how a non-block
 * body is placed relative to `do` — same line, always next line, or
 * fit-line (ψ₅). Block bodies (`{ … }`) always take a single space
 * regardless of the policy: the `{` carries its own layout via
 * `blockBody`.
 *
 * Field-level `@:trailOpt(';')` covers nested-do-while: in
 * `do do x; while(a); while(b);` the outer body is
 * `InnerDoWhile(inner)`; the `;` after inner's `)` is consumed at
 * this field-level slot (mirrors pre-slice-53 behaviour when body
 * was `HxStatement` carrying its own `@:trailOpt(';')`).
 */
@:peg
typedef HxDoWhileStmt = {
	@:trailOpt(';') @:fmt(bodyPolicy('doBody')) var body:HxDoWhileBody;
	@:kw('while') @:lead('(') @:trail(')') @:fmt(sameLine('sameLineDoWhile')) var cond:HxExpr;
};

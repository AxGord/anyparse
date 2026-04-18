package anyparse.grammar.haxe;

/**
 * If-statement grammar.
 *
 * Structure: `if (cond) thenBody [else elseBody]`.
 *
 * The condition is wrapped in mandatory parentheses (`@:lead('(')` /
 * `@:trail(')')` on the `cond` field — the trail-on-Ref pattern that
 * `Lowering.lowerStruct` already supports). The then-body is a bare
 * `HxStatement` Ref field — any statement branch (including
 * `BlockStmt`) is accepted. The else-body is `@:optional @:kw('else')`
 * — the `else` keyword is the commit point; when absent, `elseBody` is
 * null.
 *
 * `@:sameLine("sameLineElse")` on `elseBody` makes the writer's
 * separator between the then-body and `else` runtime-switchable: when
 * the flag is true (haxe-formatter default) the separator is a plain
 * space (`} else {`); when false it becomes a hardline at the current
 * indent level (`}\n    else {`).
 *
 * `@:shapeAware` (no argument — ψ₉) opts the `@:sameLine` flag into
 * shape-awareness on the preceding sibling: when `thenBody` is a
 * non-block statement whose bodyPolicy forced it onto its own line,
 * the space is suppressed in favour of a hardline regardless of the
 * flag — a lone `else` on the same line as a semicolon-terminated
 * body makes no sense. Other `@:sameLine` sites (`HxDoWhileStmt.cond`,
 * `HxTryCatchStmt.catches`) intentionally omit this meta because
 * `while`/`catch` are integral to the loop/try structure and stay
 * inline with the preceding body terminator regardless of shape.
 *
 * `@:elseIf` on `elseBody` (no argument — ψ₆ principle) activates the
 * `opt.elseIf:KeywordPlacement` knob for the `IfStmt` ctor only:
 * when the else branch is itself an if, the separator between `else`
 * and the nested if is picked from `opt.elseIf` instead of the field's
 * own `@:bodyPolicy`, so `else if (...)` stays inline by default even
 * though `elseBody=Next` pushes non-if branches to the next line.
 *
 * Dangling else is resolved correctly by construction: the inner `if`
 * greedily consumes the nearest `else`, leaving outer `if`s with no
 * else branch.
 */
@:peg
typedef HxIfStmt = {
	@:lead('(') @:trail(')') var cond:HxExpr;
	@:bodyPolicy('ifBody') var thenBody:HxStatement;
	@:optional @:kw('else') @:sameLine('sameLineElse') @:shapeAware @:bodyPolicy('elseBody') @:elseIf var elseBody:Null<HxStatement>;
};

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
 * `@:fmt(sameLine("sameLineElse"))` on `elseBody` makes the writer's
 * separator between the then-body and `else` runtime-switchable: when
 * the flag is true (haxe-formatter default) the separator is a plain
 * space (`} else {`); when false it becomes a hardline at the current
 * indent level (`}\n    else {`).
 *
 * `@:fmt(shapeAware)` (no argument — ψ₉) opts the sameLine flag into
 * shape-awareness on the preceding sibling: when `thenBody` is a
 * non-block statement whose bodyPolicy forced it onto its own line,
 * the space is suppressed in favour of a hardline regardless of the
 * flag — a lone `else` on the same line as a semicolon-terminated
 * body makes no sense. Other sameLine sites (`HxDoWhileStmt.cond`,
 * `HxTryCatchStmt.catches`) intentionally omit this flag because
 * `while`/`catch` are integral to the loop/try structure and stay
 * inline with the preceding body terminator regardless of shape.
 *
 * `@:fmt(elseIf)` on `elseBody` (no argument — ψ₆ principle) activates
 * the `opt.elseIf:KeywordPlacement` knob for the `IfStmt` ctor only:
 * when the else branch is itself an if, the separator between `else`
 * and the nested if is picked from `opt.elseIf` instead of the field's
 * own bodyPolicy, so `else if (...)` stays inline by default even
 * though `elseBody=Next` pushes non-if branches to the next line.
 *
 * `@:fmt(fitLineIfWithElse)` on BOTH `thenBody` and `elseBody` (ψ₁₂)
 * gates the `FitLine` body policy on sibling-else presence at runtime:
 * when `opt.fitLineIfWithElse` is `false` (default) and the `if` has
 * an `else` clause, the body falls back to `Next` layout (hardline +
 * indent + body) regardless of the `FitLine` policy. Matches haxe-
 * formatter's `sameLine.fitLineIfWithElse: @:default(false)` — fitting
 * one half of an if/else on one line and breaking the other reads as
 * inconsistent, so the default degrades both halves together. The
 * macro discovers the sibling field name via `lowerStruct`'s
 * `optionalBodyFieldName` scan, so only the flag needs to be present
 * here — no explicit sibling reference.
 *
 * Dangling else is resolved correctly by construction: the inner `if`
 * greedily consumes the nearest `else`, leaving outer `if`s with no
 * else branch.
 */
@:peg
typedef HxIfStmt = {
	@:lead('(') @:trail(')') var cond:HxExpr;
	@:fmt(bodyPolicy('ifBody'), fitLineIfWithElse) var thenBody:HxStatement;
	@:optional @:kw('else') @:fmt(sameLine('sameLineElse'), shapeAware, bodyPolicy('elseBody'), elseIf, fitLineIfWithElse) var elseBody:Null<HxStatement>;
};

package anyparse.grammar.haxe;

/**
 * While-loop grammar.
 *
 * Structure: `while (cond) body`.
 *
 * The condition is wrapped in mandatory parentheses. The body is a bare
 * `HxStatement` Ref field — any statement branch (including
 * `BlockStmt`) is accepted. Uses only existing Lowering patterns:
 * `@:lead` / `@:trail` on a Ref field and a bare Ref field.
 *
 * `@:fmt(trailOptKeepIf('elementIsConditional_HxStatement'))` on the body keeps the
 * `@:trailOpt(';')` slot after a `#if` region, whose last branch may end unterminated
 * (`#if d b() #else c() #end;`): there the `;` is the statement's terminator, not a redundant one.
 */
@:peg
typedef HxWhileStmt = {
	@:lead('(') @:trail(')') @:fmt(condWrap('conditionWrap'), condParensInside('whileCondParensInsideOpen', 'whileCondParensInsideClose'),
		captureCondOpenNewline) var cond: HxExpr;
	@:trailOpt(';') @:fmt(bodyPolicy('whileBody'), dropSingleStmtBraces, trailOptKeepIf('elementIsConditional_HxStatement'),
		loopBodyIfElseNext('loopBodyIfElseNext', 'IfStmt', 'elseBody')) var body: HxStatement;
};

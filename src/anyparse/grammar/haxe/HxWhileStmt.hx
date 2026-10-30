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
 * The body's `@:trailOpt(';')` slot is written back from source presence: a `;` after a block
 * body is redundant and the `empty-statement` lint's to remove, while after a `#if` region whose
 * last branch ends unterminated (`#if d b() #else c() #end;`) it is the statement's terminator.
 */
@:peg
typedef HxWhileStmt = {
	@:lead('(') @:trail(')') @:fmt(condWrap('conditionWrap'), condParensInside('whileCondParensInsideOpen', 'whileCondParensInsideClose'),
		captureCondOpenNewline) var cond: HxExpr;
	@:trailOpt(';') @:fmt(bodyPolicy('whileBody'), dropSingleStmtBraces, loopBodyIfElseNext('loopBodyIfElseNext', 'IfStmt', 'elseBody'))
	var body: HxStatement;
};

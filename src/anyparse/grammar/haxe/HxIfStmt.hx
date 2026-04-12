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
 * Dangling else is resolved correctly by construction: the inner `if`
 * greedily consumes the nearest `else`, leaving outer `if`s with no
 * else branch.
 */
@:peg
typedef HxIfStmt = {
	@:lead('(') @:trail(')') var cond:HxExpr;
	var thenBody:HxStatement;
	@:optional @:kw('else') var elseBody:Null<HxStatement>;
};

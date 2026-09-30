package anyparse.grammar.haxe;

/**
 * `target = #if c v; [#elseif d w;] #else u; #end` at statement level (`HxStatement.CondSemiAssignStmt`). `target` is
 * an ATOM-level operand — the postfix chain included (`this.a[i].b`), no operator — so the statement parser never
 * enters the Pratt loop that would read the statement after the `#end` as the value's continuation.
 */
@:peg
typedef HxCondSemiAssign = {
	@:fmt(atomOperand) var target: HxExpr;
	var value: HxCondSemiValue;

	/**
	 * No `;` after the `#end`: with every branch ending in its own `;` the next statement follows, and a `;` there is
	 * where a region of bare values (`x = #if a 1 #else 2 #end;`) puts its terminator.
	 */
	@:fmt(fillSeam) var end: HxNoSemiAhead;
};

package anyparse.grammar.haxe;

/**
 * One `<operand> <operator>` pair of a token-splice conditional's
 * fragment — the unit `HxCondSpliceOpExpr` repeats.
 *
 * `@:fmt(atomOperand)` is the whole mechanism. It binds `operand` at
 * ATOM level (`parseHxExprAtom`), which is the postfix WRAPPER around
 * the leaf/prefix parser — so a term's operand still covers
 * `!image.powerOfTwo`, `session.packageName`, `toGBStr(total)`,
 * `new A(1, 2)` and every other prefix/postfix shape, and stops dead
 * at the first BINARY operator instead of entering the Pratt loop.
 *
 * That is what makes the dangling-operator fragment parseable at all.
 * A production `{expr:HxExpr, op}` with `expr` at full precedence
 * cannot work: the Pratt loop consumes the trailing operator and then
 * throws on the missing right operand, and `Lowering.lowerPrattLoop`
 * emits no failure rewind (measured: zero `try` and zero `catch`
 * across its 14.5 KB, 41 of 42 `ctx.pos = _savedPos` writes being the
 * min-precedence gate). Nothing here asks it to. The rewind this
 * production needs is the one a Star ALREADY has — `@:tryparse` on
 * `HxCondSpliceOpExpr.terms` rolls the last, operator-less operand
 * back so the `#end` is still there for the field after it.
 */
@:peg
typedef HxCondSpliceOpTerm = {
	@:fmt(atomOperand) var operand: HxExpr;
	var op: HxCondSpliceOpLit;
};

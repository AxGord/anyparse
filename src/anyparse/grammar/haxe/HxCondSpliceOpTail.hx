package anyparse.grammar.haxe;

/**
 * POST-operand token-splice conditional whose fragment is a LEADING infix
 * operator plus its right operand - `<operand> #if <cond> <op> <expr> #end`,
 * the mirror of `HxCondSpliceOpExpr`. The enclosing `HxExpr.CondSpliceTail`
 * ctor consumes the `#if` and owns the operand before it; `endKw` is the
 * closing directive (a TERMINAL, see `HxCondEndLit`).
 *
 * WHY THIS ONE NEEDS NO ATOM-LEVEL BIND, unlike the pre-operand mirror.
 * `HxCondSpliceOpExpr` binds each operand at ATOM level because its fragment
 * ENDS on a dangling operator, and a full-precedence parse would hand that
 * operator to the Pratt loop, which throws on the missing right operand with
 * no rewind of its own (`PrattPostfixLowering.lowerPrattLoop`). Here the
 * fragment ends on a COMPLETE operand, so the loop is entered on a
 * well-formed expression and stops at the `#end` it cannot read as an
 * operator. `#if m + a * b #end` therefore projects one real `Mul` node
 * rather than a flat run of pairs.
 *
 * ORDERED CHOICE inside `HxCondSpliceTailBody`: this branch is tried first,
 * the comma-led `HxCondSpliceListTail` second, the raw capture last. A
 * fragment neither structured branch can represent fails on the `#end`
 * terminal and falls through to that capture, so the fallback is narrowed,
 * not removed - the enum's per-branch rewind is what makes the
 * fall-through possible, which the POSTFIX dispatch cannot do.
 *
 * ASSOCIATIVITY. The operator is bound to a compilation branch, not to a
 * precedence tree: `A + B #if c - D #end` is `A + B - D` with `c` on and
 * `A + B` with it off, so the model deliberately does not join `op` to the
 * operand on the other side of the `#if`. Byte round-trip is exact either
 * way, which is what the region owes.
 *
 * LAYOUT IS THIS RULE'S OWN - `@:fmt(fillParts)` joins the four fields with
 * a single space while the line holds them and packs them (Wadler fill) when
 * it does not, so the same tree lays out the same way however the source
 * spelled the region. No source-newline slot is read inside the region.
 */
@:peg
@:fmt(fillParts)
typedef HxCondSpliceOpTail = {
	var cond: HxPpCondLit;
	@:fmt(fillSeam) var op: HxCondSpliceOpLit;
	@:fmt(fillSeam) var operand: HxExpr;
	@:fmt(fillSeam) var endKw: HxCondEndLit;
};

package anyparse.grammar.haxe;

/**
 * Operand-position token-splice conditional whose fragment is a run of complete operands
 * each followed by an operator — `#if <cond> (<operand> <op>)* #end <tail>`, the
 * dangling-infix-operator shape (`"a" + #if !flash "b" + x + #end "c"`). The enclosing
 * `HxExpr.CondSpliceOpExpr` ctor consumes the `#if`; `cond` is the condition atom; `terms`
 * the run; `endKw` the closing directive (a TERMINAL, see `HxCondEndLit` for why not a
 * `@:kw`); `tail` parses the continuation the fragment splices onto.
 *
 * WHY THIS DOES NOT NEED A PRATT REWIND. The obvious production `{cond, expr:HxExpr, op,
 * tail}` binds `expr` at FULL precedence, and then the Pratt loop consumes the dangling
 * operator and throws on the missing right operand — `PrattPostfixLowering.lowerPrattLoop`
 * emits no `try`/`catch`. But prefix and postfix do NOT live in that loop: `parseHxExprAtom`
 * is the postfix wrapper around `parseHxExprAtomCore`, and `@:prefix` recurses into it. So an
 * ATOM-level operand covers everything a site puts between its operators and stops at the
 * operator — and the run becomes a Star, whose `@:tryparse` element rewind is machinery
 * `HxConditionalExpr.elseifs` already uses. `a + ;` outside a region still errors at `+`.
 *
 * ORDERED CHOICE. Dispatch is AFTER `ConditionalExpr` and `ConditionalArgs` and BEFORE
 * `CondSpliceExpr` (the raw byte capture). A fragment this production cannot represent — one
 * carrying its own `#else`, an unbalanced nested `#if`, a `;`-terminated branch — fails on
 * the `#end` terminal and falls through to the raw capture, so the fallback is narrowed, not
 * removed. ASSOCIATIVITY: `terms` is a FLAT run, not a precedence tree — the operators
 * associate with operands on the other side of the `#end` that the model deliberately does
 * not join; byte round-trip is exact either way. The POST-operand mirror is `HxCondSpliceTailBody`.
 *
 * LAYOUT IS THIS RULE'S OWN, not the source's — `@:fmt(fillParts)`. The default writer for a
 * trivia-bearing rule replays the source gaps, which for a run of operands means the SAME
 * tree lays out as many ways as the source can spell it. So the rule assembles its four
 * fields as ONE run: `fillParts` on the typedef joins them with a single space while the
 * line holds them and packs them (Wadler fill) when it does not; `fillSeam` on `endKw` and
 * `tail` hands those two gaps to that run; `fillItems` does the same for the operand terms;
 * `inlineSep` on `HxCondSpliceOpTerm.op` keeps an operator glued to the operand it closes. A
 * run carrying a captured COMMENT falls back to the source-faithful emit. THE OPERATOR IS
 * BOUND TO A COMPILATION BRANCH (`A + #if c B + #end D` is `A + B + D` with `c` on and `A +
 * D` off), so the layout changes WHITESPACE only — no fill decision can reorder tokens.
 *
 * `HaxeQueryPlugin.opaqueCondRegionKinds` still lists this ctor, not as a leftover:
 * `RefactorSupport.opaqueCondRegionMentioning` walks the parts of an opaque node's span NO
 * CHILD covers, so the `#if`/`#end` bytes and the operator slices stay under the guard.
 */
@:peg
@:fmt(fillParts)
typedef HxCondSpliceOpExpr = {
	var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, fillItems) var terms: Array<HxCondSpliceOpTerm>;
	@:fmt(fillSeam) var endKw: HxCondEndLit;
	@:fmt(chainNestSuppress, fillSeam) var tail: HxExpr;
};

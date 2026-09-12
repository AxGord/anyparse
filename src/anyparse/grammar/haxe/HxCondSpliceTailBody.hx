package anyparse.grammar.haxe;

/**
 * Body of a POST-operand token-splice `#if` region - what
 * `HxExpr.CondSpliceTail` parses after the postfix directive.
 *
 * An Alt-enum rather than a direct Ref because ORDERED CHOICE WITH REWIND
 * is the whole mechanism. Two `@:postfix('#if')` ctors cannot express it:
 * `PrattPostfixLowering.lowerPostfixLoop` emits one `if` / `else if` chain
 * keyed on the operator literal with no rollback, so the first arm
 * spelling `#if` commits unconditionally and the second is dead code -
 * measured, both arms present in the generated engine under the identical
 * guard. An `@:peg` enum branch is wrapped in `Lowering.tryBranch`, which
 * restores `ctx.pos` on a `ParseError`, so a fragment the structured
 * branches cannot represent falls through to `RawTail` exactly as the whole shape did before.
 *
 * Branch order is the dispatch: `OpTail` claims a leading infix operator,
 * `ListTail` a leading comma, `RawTail` everything else - a fragment carrying its
 * own `#else`, an unbalanced nested `#if`, an object-literal field, a multi-element
 * comma run, a mixed operator/comma run, an `else`-led if-chain continuation. The two
 * structured branches are disjoint on the first token after the condition
 * atom, so their relative order is documentation rather than a tiebreak.
 */
@:peg
enum HxCondSpliceTailBody {

	OpTail(inner: HxCondSpliceOpTail);
	ListTail(inner: HxCondSpliceListTail);
	RawTail(raw: HxCondSpliceRaw);

}

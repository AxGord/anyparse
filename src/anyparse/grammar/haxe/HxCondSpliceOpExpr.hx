package anyparse.grammar.haxe;

/**
 * Operand-position token-splice conditional whose fragment is a run of
 * complete operands each followed by an operator — `#if <cond>
 * (<operand> <op>)* #end <tail>`. The enclosing `HxExpr.
 * CondSpliceOpExpr` ctor consumes the `#if`; `cond` is the condition
 * atom; `terms` is the run; `endKw` is the closing directive (a TERMINAL,
 * see `HxCondEndLit` for why not a `@:kw`); and `tail` parses the
 * continuation the fragment splices onto.
 *
 * This is the shape EIGHT of the nine surviving `CondSpliceExpr`
 * regions in a 1646-module census have (TM `src/`, `lime/src`,
 * `openfl/src`) — a dangling infix operator:
 *
 *  - `+` — TM `crashdumper/SystemData.hx:137`, `crashdumper/CrashDumper.hx:307`
 *  - `||` — `openfl/geom/PerspectiveProjection.hx:116`,
 *    `openfl/display/BitmapData.hx:2229` and `:2239`,
 *    `openfl/display3D/textures/TextureBase.hx:289`
 *  - `&&` — `lime/utils/Preloader.hx:233`, `lime/system/System.hx:590`
 *
 * and the NINTH is reached by the same production because a ternary's
 * `?` / `:` are operators in `HxCondSpliceOpLit`: TM
 * `popups/fileDialog/FileDialog.hx:91`'s `#if FEATURE_SHARE share ?
 * new A(…) : #end new B(…)` is two terms, `(share, ?)` and
 * `(new A(…), :)`.
 *
 * WHY THIS DOES NOT NEED A PRATT REWIND, which an earlier slice
 * concluded it did. The obvious production `{cond, expr:HxExpr, op,
 * tail}` binds `expr` at FULL precedence, and then the Pratt loop
 * consumes the dangling operator and throws on the missing right
 * operand — `Lowering.lowerPrattLoop` emits no `try`/`catch` anywhere,
 * so the throw escapes the whole `parseHxExpr`. All true. But prefix
 * and postfix do NOT live in that loop: `HxExpr`'s own contract is
 * that `parseHxExprAtom` is the postfix wrapper around
 * `parseHxExprAtomCore`, and `@:prefix` recurses into it. So an
 * ATOM-level operand covers everything the nine sites put between
 * their operators and stops at the operator — and the run becomes a
 * Star, whose element rewind (`@:tryparse`) is machinery that has
 * shipped since `HxConditionalExpr.elseifs`. The operator loop is
 * never entered, so it never needs to unwind; `a + ;` still errors at
 * the `+` exactly as before, because nothing outside a `#if` region
 * reaches this ctor.
 *
 * ORDERED CHOICE. Dispatch is AFTER `ConditionalExpr` (balanced single
 * expression per branch) and `ConditionalArgs` (comma-separated
 * element groups) and BEFORE `CondSpliceExpr` (the raw byte capture).
 * A fragment this production cannot represent — one carrying its own
 * `#else`, an unbalanced nested `#if`, a `;`-terminated branch — fails
 * on the `#end` terminal and falls through to the raw capture
 * exactly as before, so the fallback is narrowed, not removed.
 *
 * ASSOCIATIVITY. `terms` is a FLAT run, not a precedence tree: the
 * fragment is a token splice, and the operators inside it associate
 * with operands on the other side of the `#end` that the model
 * deliberately does not join. `HxCondSpliceExpr` already records the
 * same divergence for its `tail`. Byte round-trip is exact either way,
 * which is what the region owes.
 *
 * THE MIRROR CASE IS NOT FREE, and that was measured rather than
 * assumed. A POST-operand splice — `A + B #if mobile - 120 #end`,
 * `HxExpr.CondSpliceTail`, 26 regions in 16 files of the same census —
 * is the same shape with the term order reversed (`(op, operand)`
 * pairs), and a `@:postfix('#if') CondSpliceOpTail(operand, inner)`
 * ctor written next to the raw one parses every sampled site and
 * round-trips them byte-for-byte. It still never fires. The postfix
 * dispatch is not an ordered choice: `Lowering.lowerPostfixLoop` emits
 * one `if` / `else if` chain keyed on the operator literal with, in its
 * own words, "no precedence gate and no `_savedPos` rollback — once a
 * postfix operator matches, the body commits". Two branches spelling
 * `#if` therefore compile to two arms of one chain, the first wins
 * unconditionally, and the second is dead code — read out of the
 * generated engine, both arms present, both guarded by the identical
 * `peekLit(ctx,"#if") && … && matchKw(ctx,"#if")`. Reordering does not
 * help either: whichever arm is first COMMITS, so a fragment it cannot
 * represent throws instead of falling through to the raw capture.
 * Reaching those 26 regions needs either a rewind in the postfix loop
 * or an Alt-typed body on `CondSpliceTail` (an `@:peg` enum HAS the
 * rewind), and both change a ctor 26 live regions depend on. A
 * separate slice, with its own fidelity surface — not this one.
 *
 * `HaxeQueryPlugin.opaqueCondRegionKinds` still lists this ctor. That
 * is not a leftover: `RefactorSupport.opaqueCondRegionMentioning`
 * walks the parts of an opaque node's span NO CHILD covers, so listing
 * it keeps the `#if`/`#end` keyword bytes and the operator slices
 * under the guard while every operand — the part that can spell a name
 * — is now a real node the scan reads directly. The refusal narrows to
 * exactly what stayed unmodelled.
 */
@:peg
typedef HxCondSpliceOpExpr = {
	var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading) var terms: Array<HxCondSpliceOpTerm>;
	var endKw: HxCondEndLit;
	@:fmt(chainNestSuppress) var tail: HxExpr;
};

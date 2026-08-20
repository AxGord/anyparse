package anyparse.grammar.haxe;

/**
 * Operand-position token-splice conditional: `#if <cond> <fragment>
 * #end <tail-operand>` where the fragment is NOT a balanced
 * expression (see `HxCondSpliceRaw`). The enclosing
 * `HxExpr.CondSpliceExpr` ctor consumes the `#if`; `raw` swallows
 * everything through the `#end`; `tail` parses the continuation
 * operand the fragment splices onto:
 *
 *  - `endl + #if !flash "b" + endl + #end "c" + y` — `raw` carries
 *    `!flash "b" + endl + ` and `tail` binds `"c" + y`. The tail is a full expression parse, so the
 *    right-hand chain nests into it — byte round-trip is exact even
 *    though the AST associativity differs from the flat source chain
 *    (acceptable: splice regions are opaque).
 *  - `#if share cond ? new A(...) : #end new B(...)` — `raw` carries
 *    the half-ternary head, `tail` the shared else-operand.
 *
 * Dispatch order: LAST — after `ConditionalExpr` (balanced
 * single-expr), `ConditionalArgs` (list-element groups) and
 * `CondSpliceOpExpr` (operand-run fragments); all three fail-rewind
 * onto this one, so every structurally-parseable conditional keeps its
 * structured representation and only the genuinely unmodellable
 * fragment reaches the raw capture.
 *
 * WHAT THIS PRODUCTION IS STILL FOR, after `HxCondSpliceOpExpr`.
 * A census over 1646 real modules (TM `src/`, `lime/src`,
 * `openfl/src`) found nine regions reaching this ctor, and EIGHT were
 * one shape: an ordinary operand run ending on a dangling infix
 * operator whose right operand is the `tail` (`+` in
 * `crashdumper/SystemData.hx:137` and `crashdumper/CrashDumper.hx:307`,
 * `||` in `openfl/geom/PerspectiveProjection.hx:116`,
 * `openfl/display/BitmapData.hx:2229` and `:2239`,
 * `openfl/display3D/textures/TextureBase.hx:289`, `&&` in
 * `lime/utils/Preloader.hx:233`, `lime/system/System.hx:590`). All
 * eight are now `HxCondSpliceOpExpr`, dispatched one branch earlier,
 * with every operand a real node.
 *
 * An earlier reading held that they COULD not be: the obvious
 * production `{cond, expr:HxExpr, op, tail:HxExpr}` needs the Pratt
 * loop to REWIND an operator whose right operand fails to parse, and
 * `Lowering.lowerPrattLoop` has no such path — every branch reads
 * `left = HxExpr.Add(left, parseHxExpr(ctx, prec + 1))` with zero
 * `try` and zero `catch` across its 14.5 KB, and 41 of its 42
 * `ctx.pos = _savedPos` writes are the MIN-PRECEDENCE gate. That
 * measurement is correct and still holds. What it missed is that
 * `expr` does not have to be a full-precedence expression: prefix and
 * postfix live in `parseHxExprAtom`, so an ATOM-level operand covers
 * every operand those eight sites actually write and stops at the
 * operator, turning the fragment into a Star of `(operand, operator)`
 * pairs whose rewind is `@:tryparse`. The operator loop is never
 * entered, so it never needs to unwind, and `a + ;` still errors at
 * the `+`.
 *
 * What is left here is everything that is NOT such a run: a fragment
 * carrying its own `#else`, an unbalanced nested `#if`, a
 * `;`-terminated branch, a `@meta`-prefixed statement region — and one
 * census site kept here deliberately, `#if c cond ? a : #end b` (TM
 * `popups/fileDialog/FileDialog.hx:91`). That one PARSES as two terms
 * the moment `?` and `:` join `HxCondSpliceOpLit`; it stays raw
 * because a flat term run cannot reproduce its two-level hand indent
 * and `hxq fmt` would start rewriting a file it leaves alone today.
 * The measurement and the one-token reversal are on
 * `HxCondSpliceOpLit`.
 *
 * The consequence is owned rather than hidden: `HaxeQueryPlugin.
 * opaqueCondRegionKinds` lists this ctor, so `RefactorSupport.
 * opaqueCondRegionDiagnostic` REFUSES any rename / inline / move whose
 * name is spelled in these bytes, loudly, instead of rewriting the
 * occurrences it can see. `refs` and `mentions` under-report there for
 * the same reason. `test/unit/HxCondSpliceExprSliceTest.hx` pins all
 * three shapes and their verdicts.
 */
@:peg
typedef HxCondSpliceExpr = {
	var raw: HxCondSpliceRaw;
	@:fmt(chainNestSuppress) var tail: HxExpr;
}

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
 * Dispatch order: AFTER `ConditionalExpr` (balanced single-expr) and
 * `ConditionalArgs` (list-element groups) — both fail-rewind on
 * splice shapes, so every structurally-parseable conditional keeps
 * its structured representation.
 *
 * WHY THE FRAGMENT CANNOT BE MODELLED AS `<HxExpr> <dangling op>`.
 * A census over 1649 real modules (TM `src/`, `lime/src`, `openfl/src`)
 * finds eleven regions reaching this ctor, and EIGHT are one shape:
 * an ordinary expression followed by a dangling infix operator whose
 * right operand is the `tail` (`+` in `crashdumper/SystemData.hx:137`
 * and `crashdumper/CrashDumper.hx:307`, `||` in
 * `openfl/geom/PerspectiveProjection.hx:116`,
 * `openfl/display/BitmapData.hx:2229` and `:2239`,
 * `openfl/display3D/textures/TextureBase.hx:289`, `&&` in
 * `lime/utils/Preloader.hx:233`, `lime/system/System.hx:590`). A
 * production `{cond, expr:HxExpr, op, tail:HxExpr}` would give all
 * eight real nodes — and it is not expressible, because it needs the
 * Pratt loop to REWIND an operator whose right operand fails to parse.
 * `Lowering.lowerPrattLoop` has no such path: every branch reads
 *
 * ```js
 * left = HxExpr.Add(left, parseHxExpr(ctx, prec + 1));
 * ```
 *
 * with no `try`/`catch` anywhere in the generated loop (measured: zero
 * of each across its 14.5 KB, and 41 of the 42 `ctx.pos = _savedPos`
 * writes are the MIN-PRECEDENCE gate, not a failure rewind). A failing
 * right operand therefore throws out of the whole `parseHxExpr`, so
 * `expr` can never stop one operator short of where the fragment ends.
 *
 * Adding the rewind is a core-codegen change affecting every infix
 * operator of every grammar, and it would also silently accept genuine
 * typos: `a + ;` would parse as `a` with `+ ;` left for the next field
 * instead of erroring at the `+`. So the eight sites stay RAW, by
 * decision — as does the ninth shape, `#if c cond ? a : #end b` (TM
 * `popups/fileDialog/FileDialog.hx:91`), whose fragment is half a
 * ternary and has the same missing-operand problem.
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

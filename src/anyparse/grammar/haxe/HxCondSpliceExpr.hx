package anyparse.grammar.haxe;

/**
 * Operand-position token-splice conditional: `#if <cond> <fragment> #end <tail-operand>`
 * where the fragment is NOT a balanced expression (see `HxCondSpliceRaw`). The enclosing
 * `HxExpr.CondSpliceExpr` ctor consumes the `#if`; `raw` swallows everything through the
 * `#end`; `tail` parses the continuation operand the fragment splices onto — in `endl + #if
 * !flash "b" + endl + #end "c" + y`, `raw` carries `!flash "b" + endl + ` and `tail` binds
 * `"c" + y`; in `#if share cond ? new A(...) : #end new B(...)`, `raw` carries the
 * half-ternary head and `tail` the shared else-operand. The tail is a full expression
 * parse, so the right-hand chain nests into it — byte round-trip is exact even though the
 * AST associativity differs from the flat source chain (splice regions are opaque).
 *
 * Dispatch order: LAST — after `ConditionalExpr` (balanced single-expr), `ConditionalArgs`
 * (list-element groups) and `CondSpliceOpExpr` (operand-run fragments); all three
 * fail-rewind onto this one, so every structurally parseable conditional keeps its
 * structured representation and only the genuinely unmodellable fragment reaches the raw
 * capture. The dangling-infix-operator run (`a + #if c b + #end d`) that used to dominate
 * this ctor is `HxCondSpliceOpExpr` now, with every operand a real node; what is left here
 * is everything that is NOT such a run — a fragment carrying its own `#else`, an unbalanced
 * nested `#if`, a `;`-terminated branch, a `@meta`-prefixed statement region — and the
 * half-ternary, kept raw deliberately because a flat term run cannot reproduce its
 * two-level hand indent (see `HxCondSpliceOpLit`).
 *
 * The consequence is owned rather than hidden: `HaxeQueryPlugin.opaqueCondRegionKinds` lists
 * this ctor, so `RefactorSupport.opaqueCondRegionDiagnostic` REFUSES any rename / inline /
 * move whose name is spelled in these bytes, loudly, instead of rewriting the occurrences
 * it can see; `refs` and `mentions` under-report there for the same reason.
 * `test/unit/HxCondSpliceExprSliceTest.hx` pins the shapes and their verdicts.
 */
@:peg
typedef HxCondSpliceExpr = {
	var raw: HxCondSpliceRaw;
	@:fmt(chainNestSuppress) var tail: HxExpr;
}

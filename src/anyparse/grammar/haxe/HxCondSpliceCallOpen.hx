package anyparse.grammar.haxe;

/**
 * Operand-position token-splice conditional whose every branch opens a call or a parenthesis
 * that the shared tail closes: `#if haxe4 TNamed(a.name, #else ( #end toComplexType(a.t))`.
 * The enclosing `HxExpr.CondSpliceCallOpenExpr` ctor consumes the `#if` and the closing `)`;
 * `raw` swallows everything through the `#end` (see `HxCondSpliceCallOpenRaw`) and `tail`
 * parses the shared operand. Opaque the way `HxCondSpliceExpr` is: a name spelled in `raw` is
 * invisible to `refs` and refused by the renaming ops.
 */
@:peg
typedef HxCondSpliceCallOpen = {
	var raw: HxCondSpliceCallOpenRaw;
	@:fmt(chainNestSuppress) var tail: HxExpr;
}

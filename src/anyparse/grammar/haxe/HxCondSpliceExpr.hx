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
 */
@:peg
typedef HxCondSpliceExpr = {
	var raw: HxCondSpliceRaw;
	@:fmt(chainNestSuppress) var tail: HxExpr;
}

package anyparse.grammar.haxe;

/**
 * For-loop statement grammar.
 *
 * Shape: `for (varName in iterable) body`.
 *
 * The opening `(` is a literal lead on the `varName` field. The `in`
 * keyword is a `@:kw` lead on the `iterable` field (word-boundary
 * enforced via `expectKw`). The closing `)` is a literal trail on the
 * `iterable` field. The `body` is a bare `HxStatement` Ref — any
 * statement branch (including `BlockStmt`) is accepted.
 *
 * Zero Lowering changes: `@:kw` + `@:trail` on the same field already
 * work in `lowerStruct` — kw lead emits `expectKw` (line 912-914),
 * trail emits `expectLit` (line 985-987). The expression parser
 * returns cleanly on `)` because no Pratt/postfix operator matches it.
 */
@:peg
typedef HxForStmt = {
	@:lead('(') var varName:HxIdentLit;
	@:kw('in') @:trail(')') var iterable:HxExpr;
	var body:HxStatement;
};

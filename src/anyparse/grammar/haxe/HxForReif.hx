package anyparse.grammar.haxe;

/**
 * Body of `HxExpr.ForReifExpr` — a `for` whose parenthesised head is
 * a SINGLE expression rather than the structured
 * `var [=> value] in iterable` shape `HxForExpr` requires. Covers
 * macro-reification for-patterns whose head slots are spliced:
 *
 *  - `for ($head) $body` — the whole head is one reification
 *  - `for ($i{_} in $_) $_` — the iterator var is a reification
 *    (`in` parses as the prec-0 infix `In`)
 *  - `for (key => $i{names[0]} in $i{ref}) …` — the map-iteration
 *    value slot is a reification (`=>` parses as the prec-0 infix
 *    `Arrow`)
 *
 * The structured `HxForExpr` stays the canonical representation:
 * `ForReifExpr` is ordered AFTER `ForExpr` in `HxExpr`, so it is
 * reached only when the plain-ident head grammar fail-rewinds.
 * Statement-position occurrences ride `ExprStmt` the same way other
 * keyword-atom expressions do (`ForStmt` fails first, then the
 * expression route picks the shape up).
 *
 * `body` reuses the `expressionForBody` policy knob so layout
 * behaviour matches `HxForExpr.body` (default `Keep` — source layout
 * preserved).
 */
@:peg
typedef HxForReif = {
	@:lead('(') @:trail(')') var head: HxExpr;
	@:fmt(bodyPolicy('expressionForBody')) var body: HxExpr;
};

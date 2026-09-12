package anyparse.grammar.haxe;

/**
 * POST-operand token-splice conditional whose fragment is ONE guarded
 * element of a comma-separated list - `<element> #if <cond> , <expr> #end`
 * inside a call-argument list or an array literal. The enclosing
 * `HxExpr.CondSpliceTail` ctor consumes the `#if` and owns the element
 * before it; `cond` is the condition atom, `operand` the guarded element
 * behind its own leading comma, and `endKw` the closing directive (a
 * TERMINAL, see `HxCondEndLit`).
 *
 * WHY THE ARGUMENT LIST DOES NOT OWN THIS SHAPE. `HxConditionalArgs`
 * models a region occupying whole ELEMENTS of a comma-separated list, and
 * it only fires when `#if` STARTS an element. Here the directive follows a
 * complete element, so the postfix `#if` binds inside that element's own
 * expression parse and the list Star never sees it - the same interception
 * that makes `HxExpr.CondSpliceTail` exist at all.
 *
 * ONE element, not a Star, and that is a LAYOUT limit rather than a
 * grammar one. A Star of comma-led elements parses `, a, b` perfectly, but
 * every inter-element separator this writer offers is a space or a break -
 * `sepExpr` in `WriterTriviaStarEmitLowering` is a literal `_dt(' ')` and
 * the `@:fmt(fillItems)` bypass a soft `Line(' ')` - so the second element
 * comes out as `, a , b`. Emitting a space before a comma is worse than
 * leaving the region raw, so a multi-element fragment keeps
 * `HxCondSpliceRaw`'s verbatim capture. Restoring the Star is a one-field
 * edit the day a Star can spell a tight separator.
 *
 * OBJECT LITERALS ARE NOT COVERED, and that is a parse fact rather than a
 * choice: `{a: 1 #if m , b: 2 #end}` puts a FIELD after the comma, and a
 * field name plus `:` is not an expression, so the operand parse stops at
 * the colon and the whole branch falls through to the raw capture. Array
 * elements and call arguments are both expressions, so one production
 * serves them both.
 *
 * LAYOUT. `@:fmt(spaceAfterLead)` keeps the comma tight against the
 * condition atom and one space in front of the element; `@:fmt(inlineSep)`
 * keeps one space before `#end`. Neither reads a source-newline slot, so
 * the same tree lays out the same way however the source spelled it.
 */
@:peg
typedef HxCondSpliceListTail = {
	var cond: HxPpCondLit;
	@:lead(',') @:fmt(spaceAfterLead) var operand: HxExpr;
	@:fmt(inlineSep) var endKw: HxCondEndLit;
};

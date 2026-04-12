package anyparse.grammar.haxe;

/**
 * One segment of a single-quoted Haxe string with interpolation.
 *
 * The parser tries branches in source order via `tryBranch` rollback:
 *
 *  1. `Literal` — a run of plain characters and escape sequences.
 *     Most common segment; tried first for efficiency.
 *  2. `Dollar` — `$$` escape producing a literal `$`. Must appear
 *     before `Block` and `Ident` so the two-char `$$` is consumed
 *     before the single-char `$` lead of the other branches.
 *  3. `Block` — `${expr}` interpolation. The expression inside the
 *     braces is parsed by `parseHxExpr` (recursive Ref), which is
 *     NOT `@:raw` — whitespace skipping resumes inside the expression.
 *  4. `Ident` — `$name` interpolation. The `$` lead is consumed,
 *     then `parseHxIdentLit` matches the identifier.
 *
 * `@:raw` suppresses `skipWs` in the generated parse function — every
 * character between the enclosing `'` quotes is significant.
 */
@:peg
@:raw
enum HxStringSegment {

	Literal(s:HxStringLitSegment);

	@:lit("$$")
	Dollar;

	@:lead("${") @:trail("}")
	Block(expr:HxExpr);

	@:lead("$")
	Ident(name:HxIdentLit);
}

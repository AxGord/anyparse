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
 *
 * `@:fmt(captureSource('<optionFieldName>'))` on `Block` opts the
 * trivia-pair synth ctor (`HxStringSegmentT.Block`) into a positional
 * `sourceText:String` arg holding the parser-captured byte slice
 * between `${` and `}` (inclusive of any leading / trailing whitespace
 * inside the braces). The writer reads it and gates emission on the
 * named `Bool` runtime option — when `opt.formatStringInterpolation ==
 * false`, the writer emits the captured slice verbatim instead of
 * recursing into the parsed `HxExpr`. Matches haxe-formatter's
 * `whitespace.formatStringInterpolation: false` knob, which preserves
 * the author's exact spacing inside `${…}` instead of re-rendering.
 */
@:peg
@:raw
enum HxStringSegment {

	Literal(s:HxStringLitSegment);

	@:lit("$$")
	Dollar;

	@:lead("${") @:trail("}") @:fmt(captureSource('formatStringInterpolation'))
	Block(expr:HxExpr);

	@:lead("$")
	Ident(name:HxIdentLit);
}

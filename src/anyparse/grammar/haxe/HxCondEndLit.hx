package anyparse.grammar.haxe;

/**
 * The `#end` that closes a token-splice conditional-compilation region,
 * carried as a TERMINAL field rather than a `@:kw` / `@:trail`.
 *
 * Same decision, and the same reason, as `HxCondSpliceRaw`'s "the
 * `#end` is swallowed INTO the raw match rather than living on a
 * `@:trail`": the enclosing production has to parse its continuation
 * operand immediately after the directive, and a mid-struct keyword
 * slot puts the boundary's whitespace into the keyword's own trivia
 * slots instead of the ordinary field separator. The raw splice
 * reproduces `#end\n\t\t\t'…'` byte for byte through that ordinary
 * path; `HxCondSpliceOpExpr` reproduces it the same way by spelling
 * the directive the same way.
 *
 * `@:rawString` — stored verbatim, no unescape pass.
 */
@:re('#end')
@:rawString
abstract HxCondEndLit(String) from String to String {}

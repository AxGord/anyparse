package anyparse.grammar.sexpr;

/**
 * Bare-identifier terminal for S-expressions. Any sequence of
 * non-whitespace, non-paren, non-quote characters. Written verbatim by
 * the macro-generated writer (no escape, no quote wrap).
 *
 * The `@:re` pattern exists to satisfy the macro pipeline's
 * ShapeBuilder when this terminal is referenced from an `@:peg` enum —
 * the writer half of the pipeline does not use it.
 */
@:re('[^\\s()"]+')
abstract SAtomLit(String) from String to String {}

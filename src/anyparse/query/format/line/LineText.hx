package anyparse.query.format.line;

/**
 * Verbatim text terminal for the line-diagnostic grammar. Written
 * as-is by the macro-generated writer — no quoting, no escaping —
 * exactly like `anyparse.grammar.sexpr.SAtomLit`. Used for every
 * string field of the line typedefs (file path, kind, name, binding
 * coordinate, annotation tag, argument text, …).
 *
 * The `@:re` pattern exists only so the macro pipeline's ShapeBuilder
 * accepts the terminal when referenced from an `@:peg` typedef; the
 * writer half does not use it (these grammars are writer-only).
 */
@:re('[^\\n]*')
abstract LineText(String) from String to String {}

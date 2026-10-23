package anyparse.grammar.mermaid;

/**
 * The body of an `@{ … }` data block (`shape: rect, label: "Text"`) between its braces, kept
 * verbatim but for the surrounding whitespace; a quoted value may hold a `}`.
 */
@:re('(?:(?:[^}\"\\s]|\"[^\"]*\")(?:\\s*(?:[^}\"\\s]|\"[^\"]*\"))*)?')
@:rawString
abstract MmdShapeDataLit(String) from String to String {}

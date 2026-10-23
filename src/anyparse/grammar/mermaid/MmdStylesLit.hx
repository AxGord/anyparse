package anyparse.grammar.mermaid;

/**
 * A style list (`fill:#f9f,stroke:#333,stroke-width:4px`), kept verbatim up to the line end or a
 * `;`, trailing whitespace excluded.
 */
@:re('[^\\s;](?:[^\\n;]*[^\\s;])?')
@:rawString
abstract MmdStylesLit(String) from String to String {}

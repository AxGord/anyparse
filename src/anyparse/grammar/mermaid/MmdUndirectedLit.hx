package anyparse.grammar.mermaid;

/**
 * A `flowchart` / `graph` keyword with nothing after it on its line. It asserts the line end, which
 * the newline-blind `skipWs` cannot give a direction: without it `flowchart` followed by a line
 * starting `v` or `TB` would take that node id as the direction.
 */
@:re("(?:flowchart|graph)(?=[ \\t]*(?:\\r?\\n|;|%%|$))")
@:rawString
abstract MmdUndirectedLit(String) from String to String {}

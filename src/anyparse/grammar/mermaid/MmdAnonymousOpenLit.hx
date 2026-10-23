package anyparse.grammar.mermaid;

/**
 * The `subgraph` keyword of a subgraph with no id. It asserts that nothing else stands on its line,
 * the one fact the newline-blind `skipWs` cannot give the id terminal: without it the first
 * statement of the body would be read as the id.
 */
@:re("subgraph(?=[ \\t]*(?:\\r?\\n|;|$))")
@:rawString
abstract MmdAnonymousOpenLit(String) from String to String {}

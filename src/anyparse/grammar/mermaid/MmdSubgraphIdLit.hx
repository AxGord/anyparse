package anyparse.grammar.mermaid;

/**
 * The id of a subgraph, which is also its title when no `[title]` follows: a quoted string, or the
 * rest of the `subgraph` line up to a `[` (spaces included, `subgraph Some Title`). The lookahead
 * keeps it on its own line.
 */
@:re("(?:\"[^\"]*\"|[^\\s\\[\\]\";](?:[^\\n\\r\\[\\]\";]*?[^\\s\\[\\]\";])?)(?=[ \\t]*(?:\\[|\\r?\\n|;|$))")
@:rawString
abstract MmdSubgraphIdLit(String) from String to String {}

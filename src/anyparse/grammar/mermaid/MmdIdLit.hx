package anyparse.grammar.mermaid;

/**
 * A node id (`A`, `node_1`, `a.b`, `my-node`): a run of characters that open no shape, link,
 * class suffix or edge id. A `-` or `.` belongs to the id only between two id characters, so
 * `A-->B` and `A-.->B` end the id at `A`. The statement keywords are no ids — `end` closes a
 * subgraph, and the others would read a broken statement as a node.
 */
@:re('(?!(?:end|subgraph|style|linkStyle|classDef|class|click|graph|flowchart)\\b)(?:[^\\s\\[\\](){}|\"<>&;:,~=.\\-@%#]|[.\\-](?=[^\\s\\[\\](){}|\"<>&;:,~=.\\-@%#]))+')
@:rawString
abstract MmdIdLit(String) from String to String {}

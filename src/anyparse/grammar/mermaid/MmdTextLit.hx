package anyparse.grammar.mermaid;

/**
 * A node, pipe or subgraph-title label: a quoted string (a markdown string included), or bare text
 * up to the closing bracket. A `/` or `\` ends bare text only before a `]`, which is what closes the
 * slanted shapes (`[/x/]`, `[\x\]`). The value is the decoded text (`MermaidText`).
 */
@:re('\"[^\"]*\"|(?:[^\\[\\](){}|\"\\n\\r/\\\\]|[/\\\\](?!\\]))*')
@:decode('anyparse.grammar.mermaid.MermaidText.decode')
@:encode('anyparse.grammar.mermaid.MermaidText.encode')
abstract MmdTextLit(String) from String to String {}

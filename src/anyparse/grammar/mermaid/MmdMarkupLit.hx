package anyparse.grammar.mermaid;

/**
 * A node, pipe or subgraph-title label holding markup — raw HTML (`a<br>b`), an HTML reference, or
 * an entity code `MermaidText` cannot resolve — kept as the HTML Mermaid renders. Tried after the
 * plain label, so it only ever takes a label the plain one refuses.
 */
@:re('\"(?!`)[^\"]*\"|(?:[^\\[\\](){}|\"\\n\\r/\\\\]|[/\\\\](?!\\]))+')
@:decode('anyparse.grammar.mermaid.MermaidText.decodeMarkup')
@:encode('anyparse.grammar.mermaid.MermaidText.encodeMarkup')
abstract MmdMarkupLit(String) from String to String {}

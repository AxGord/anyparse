package anyparse.grammar.mermaid;

/**
 * A markdown string, ``"`…`"``; the value is the markdown between the backticks.
 */
@:re('\"`[^`\"]*`\"')
@:decode('anyparse.grammar.mermaid.MermaidText.decodeMarkdown')
@:encode('anyparse.grammar.mermaid.MermaidText.encodeMarkdown')
abstract MmdMarkdownLit(String) from String to String {}

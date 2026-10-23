package anyparse.grammar.mermaid;

/**
 * The markup label of a `== text ==>` edge: quoted, or bare text with no `==`, kept as the HTML
 * Mermaid renders (`MermaidText`).
 */
@:re('\"(?!`)[^\"]*\"|(?:[^=\\n\\r\"]|=(?!=))+')
@:decode('anyparse.grammar.mermaid.MermaidText.decodeMarkup')
@:encode('anyparse.grammar.mermaid.MermaidText.encodeMarkup')
abstract MmdThickMarkupLit(String) from String to String {}

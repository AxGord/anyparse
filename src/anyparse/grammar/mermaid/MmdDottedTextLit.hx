package anyparse.grammar.mermaid;

/** The label of a `-. text .->` edge: quoted, or bare text with no `.-` in it. */
@:re('\"[^\"]*\"|(?:[^.\\n\\r\"]|\\.(?!-))+')
@:decode('anyparse.grammar.mermaid.MermaidText.decode')
@:encode('anyparse.grammar.mermaid.MermaidText.encodeDotted')
abstract MmdDottedTextLit(String) from String to String {}

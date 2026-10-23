package anyparse.grammar.mermaid;

/** The rest of the line after `accTitle:` / `accDescr:`, trailing whitespace excluded. */
@:re("[^\\s][^\\n]*?(?=[ \\t\\r]*(?:\\n|$))")
@:rawString
abstract MmdLineTextLit(String) from String to String {}

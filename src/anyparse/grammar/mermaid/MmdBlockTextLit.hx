package anyparse.grammar.mermaid;

/** The body of a multi-line `accDescr { … }`, kept verbatim. */
@:re('[^}]*')
@:rawString
abstract MmdBlockTextLit(String) from String to String {}

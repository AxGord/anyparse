package anyparse.grammar.mermaid;

/** A `%%` comment line, opener included, trailing whitespace excluded; `%%{` opens a directive instead. */
@:re("%%(?!\\{)[^\\n]*?(?=[ \\t\\r]*(?:\\n|$))")
@:rawString
abstract MmdCommentLit(String) from String to String {}

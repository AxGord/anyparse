package anyparse.grammar.mermaid;

/** A comma-separated node or class list with no space around the commas (`A,B,C`), kept verbatim. */
@:re('[^\\s,;]+(?:,[^\\s,;]+)*')
@:rawString
abstract MmdIdListLit(String) from String to String {}

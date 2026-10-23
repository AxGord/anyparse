package anyparse.grammar.mermaid;

/**
 * The curve of a `linkStyle … interpolate <curve>` that ends its line. The lookahead is what lets
 * the style-less form be tried first: with a style list after the curve it fails, and the
 * statement parses as `MmdLinkStyle` instead.
 */
@:re("[A-Za-z]+(?=[ \\t]*(?:\\r?\\n|;|$))")
@:rawString
abstract MmdCurveLit(String) from String to String {}

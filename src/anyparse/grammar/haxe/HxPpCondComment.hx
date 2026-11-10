package anyparse.grammar.haxe;

/** A block comment inside a condition group: comment text, so a quote or a parenthesis in it opens nothing. */
@:re('/\\*[^*]*\\*+(?:[^*/][^*]*\\*+)*/')
abstract HxPpCondComment(String) from String to String {}
